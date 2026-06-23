// Detection rules for the UI-audit smoke harness (phase 1).
//
// Pure functions only: text/geometry in → structured matches out. They hold NO
// Playwright state, so they are trivially unit-testable and the spec stays thin.
// The spec collects raw text / DOM measurements (via page.evaluate) and feeds them
// to these classifiers to produce Findings.

import type { Severity } from './report';
import {
  ABBREV_TECH_CONTEXT,
  SHORTCUT_MARKERS,
  RAW_KEY_SUFFIX_WHITELIST,
  ZH_SIMP_ONLY,
  ZH_TRAD_ONLY,
} from './whitelist';

const TOL = 2; // px tolerance for geometry comparisons

// ─────────────────────────────────────────────────────────────────────────────
// 1. Raw i18n key leak
//
// fallbackLng is zh-CN with returnEmptyString:false, so a missing key renders as
// the raw key string (e.g. "finance.cashflowTitle"). We anchor on the closed set
// of real top-level namespaces and require a letter immediately after the first
// dot (no space) so dates ("1.5") and prose ("the dashboard. Then") never match.
// ─────────────────────────────────────────────────────────────────────────────
export const I18N_NAMESPACES = [
  'accounts', 'ai', 'aiError', 'aiInsights', 'alerts', 'analysis', 'app',
  'cashAccounts', 'charts', 'chat', 'common', 'common2', 'csvImport', 'dashboard',
  'disclaimer', 'documents', 'equity', 'finance', 'fixedAssets', 'header',
  'headerTitle', 'inventory', 'invoices', 'ledgerSummary', 'liabilities', 'nav',
  'ocr', 'onboarding', 'products', 'purchases', 'sales', 'settings', 'systemError',
  'tableHeaders', 'taxPayments', 'transactions', 'units', 'usDashboard',
  'usSchedule', 'usTax',
];

function rawKeyRe(): RegExp {
  return new RegExp(
    `\\b(${I18N_NAMESPACES.join('|')})\\.[a-zA-Z][a-zA-Z0-9_]*(?:\\.[a-zA-Z0-9_]+)*`,
    'g',
  );
}

export function findRawI18nKeys(text: string): string[] {
  const re = rawKeyRe();
  const hits: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const key = m[0];
    const lastSeg = key.split('.').pop() ?? '';
    // Filename / domain / version false positives (e.g. "documents.pdf", "a.csv").
    if (RAW_KEY_SUFFIX_WHITELIST.has(lastSeg.toLowerCase())) continue;
    if (!hits.includes(key)) hits.push(key);
  }
  return hits;
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. K / k / M / 万 / 萬 number abbreviation (money & quantity)
//
// Two passes: ASCII (K/M) with a no-trailing-letter guard (so "5km", "10Mbps",
// "gpt-4-32k" never match) and CJK (万/萬). Currency-prefixed matches are always
// real money. Bare matches are suppressed only when the surrounding context is a
// keyboard shortcut or a technical/model term (context window, token count).
// ─────────────────────────────────────────────────────────────────────────────
const ABBREV_ASCII_RE = /(?<![\p{L}\p{N}._-])((?:[¥$€₩]|NT\$)?\s?\d[\d,]*(?:\.\d+)?\s?[KkMm])(?![\p{L}\p{N}])/gu;
const ABBREV_CJK_RE = /(?<![\p{N}])((?:[¥$€₩]|NT\$)?\s?\d[\d,]*(?:\.\d+)?\s?[万萬])/gu;

export type AbbrevHit = { match: string; context: string; hasCurrency: boolean; whitelisted: boolean };

function contextAround(text: string, index: number, len: number): string {
  return text.slice(Math.max(0, index - 20), index + len + 20).replace(/\s+/g, ' ').trim();
}

function isAbbrevWhitelisted(context: string): boolean {
  if (SHORTCUT_MARKERS.some((s) => context.includes(s))) return true;
  const lower = context.toLowerCase();
  if (ABBREV_TECH_CONTEXT.some((w) => lower.includes(w))) return true;
  return false;
}

export function findNumberAbbreviations(text: string): AbbrevHit[] {
  const hits: AbbrevHit[] = [];
  for (const re of [ABBREV_ASCII_RE, ABBREV_CJK_RE]) {
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      const match = m[1].trim();
      const context = contextAround(text, m.index, m[0].length);
      const hasCurrency = /[¥$€₩]|NT\$/.test(match);
      const whitelisted = !hasCurrency && isAbbrevWhitelisted(context);
      hits.push({ match, context, hasCurrency, whitelisted });
    }
  }
  return hits.filter((h) => !h.whitelisted);
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. US cross-regime tax terms
//
// With accountingLocale=US the UI must show "Sales Tax" (Schedule C basis), never
// another regime's VAT-style term. English "Sales Tax" is correct under en+US but
// is a localization residue under ja/ko/fr+US (the known formTaxRate label bug).
// ─────────────────────────────────────────────────────────────────────────────
type ForbiddenTerm = { term: string; ascii: boolean; allowEn?: boolean; label: string };

export const US_CROSS_REGIME: ForbiddenTerm[] = [
  { term: 'VAT', ascii: true, label: 'VAT (CN/EU VAT term)' },
  { term: 'TVA', ascii: true, label: 'TVA (French VAT)' },
  { term: '增值税', ascii: false, label: '增值税 (CN VAT)' },
  { term: '增值稅', ascii: false, label: '增值稅 (CN VAT, traditional)' },
  { term: '消費税', ascii: false, label: '消費税 (JP consumption tax)' },
  { term: '消费税', ascii: false, label: '消费税 (JP consumption tax, simplified)' },
  { term: '부가가치세', ascii: false, label: '부가가치세 (KR VAT)' },
  { term: 'Sales Tax', ascii: true, allowEn: true, label: "English 'Sales Tax' residue (should be localized)" },
];

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export type CrossRegimeHit = { term: string; label: string; isEnglishResidue: boolean };

export function findCrossRegimeTax(text: string, ui: string, acc: string): CrossRegimeHit[] {
  // Phase 1 only audits the US regime cross-term isolation.
  if (acc !== 'US') return [];
  const out: CrossRegimeHit[] = [];
  for (const t of US_CROSS_REGIME) {
    const present = t.ascii ? new RegExp(`\\b${escapeRe(t.term)}\\b`).test(text) : text.includes(t.term);
    if (!present) continue;
    if (t.allowEn && ui === 'en') continue; // en + US: "Sales Tax" is correct
    out.push({ term: t.term, label: t.label, isEnglishResidue: Boolean(t.allowEn) });
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Simplified / Traditional Chinese leak (wired interface, dormant in smoke)
//
// The phase-1 smoke matrix does not run zh-CN / zh-TW, so this never fires; it
// exists so a later phase can enable the check without re-deriving the char sets.
// ─────────────────────────────────────────────────────────────────────────────
export function findChineseVariantLeak(ui: string, text: string): { char: string; kind: string }[] {
  if (ui === 'zh-CN') {
    for (const c of ZH_TRAD_ONLY) if (text.includes(c)) return [{ char: c, kind: 'traditional-char-in-zh-CN' }];
  }
  if (ui === 'zh-TW') {
    for (const c of ZH_SIMP_ONLY) if (text.includes(c)) return [{ char: c, kind: 'simplified-char-in-zh-TW' }];
  }
  return [];
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Geometry classifiers (pure: measured numbers in → boolean defect out)
// ─────────────────────────────────────────────────────────────────────────────
export type Box = { top: number; bottom: number; left: number; right: number };

/** Page-level horizontal overflow. documentElement only — a wide table inside its
 *  own overflow-x-auto wrapper does NOT inflate documentElement, so intentional
 *  min-w inner scrollers are not flagged (avoids the known min-w-[1400px] noise). */
export function classifyOverflow(scrollWidth: number, innerWidth: number): boolean {
  return scrollWidth > innerWidth + TOL;
}

/** Tab strip wrapped onto >1 row → buttons no longer share offsetTop. */
export function classifyTabWrap(tops: number[]): boolean {
  if (tops.length < 2) return false;
  return Math.max(...tops) - Math.min(...tops) > TOL;
}

/** A modal action button sits outside the viewport (cannot be reached). */
export function classifyButtonOffscreen(box: Box, vw: number, vh: number): boolean {
  return box.bottom > vh + TOL || box.top < -TOL || box.right > vw + TOL || box.left < -TOL;
}

/** Modal content overflows its scroll container but the container is not scrollable. */
export function classifyModalNotScrollable(scrollH: number, clientH: number, overflowY: string): boolean {
  const overflows = scrollH > clientH + TOL;
  const scrollable = overflowY === 'auto' || overflowY === 'scroll';
  return overflows && !scrollable;
}

/** Element horizontally overflows its own client box (modal card / widget panel). */
export function classifyHOverflow(scrollW: number, clientW: number): boolean {
  return scrollW > clientW + TOL;
}

/** input[type=date].value must be empty or strict ISO YYYY-MM-DD. */
export function classifyDateValue(value: string): boolean {
  return value !== '' && !/^\d{4}-\d{2}-\d{2}$/.test(value);
}

// ─────────────────────────────────────────────────────────────────────────────
// Source-file guess (best-effort triage hint)
// ─────────────────────────────────────────────────────────────────────────────
function pageComponent(page: string, modal?: string): string {
  if (modal === 'ai-widget') return 'components/assistant/AssistantWidget.tsx';
  if (modal === 'add-purchase' || page === 'purchase') return 'components/PurchaseAndInputPage.tsx';
  if (modal === 'add-sale' || page === 'sales') return 'components/SalesAndOutputPage.tsx';
  if (page === 'finance') return 'components/FinancePage.tsx';
  if (page === 'settings') return 'components/SettingsPage.tsx';
  if (page === 'dashboard') return 'the dashboard page component (rendered from App.tsx)';
  return 'App.tsx (renderPage)';
}

export function guessSource(type: string, page: string, modal?: string): string {
  switch (type) {
    case 'raw-i18n-key':
      return `i18n/locales/<ui>.json (missing key) or ${pageComponent(page, modal)}`;
    case 'cross-regime-tax':
      return 'components/accountingLocaleConfig.ts (taxConcepts / getTaxLabel — e.g. US formTaxRate)';
    case 'number-abbreviation':
      return `components/accountingHelpers.ts (formatCompactMoney) or ${pageComponent(page, modal)}`;
    default:
      return pageComponent(page, modal);
  }
}

// Severity assignment per rule (single source of truth, mirrors the PR spec table).
export const SEVERITY: Record<string, Severity> = {
  'page-boot-failed': 'P0',
  'navigation-failed': 'P0',
  'raw-i18n-key': 'P0',
  'modal-button-offscreen': 'P0',
  'horizontal-overflow': 'P1',
  'number-abbreviation': 'P1',
  'modal-not-scrollable': 'P1',
  'modal-horizontal-overflow': 'P1',
  'ai-widget-out-of-bounds': 'P1',
  'tab-wrap': 'P2',
  'cross-regime-tax': 'P2',
  'date-value-format': 'P2',
  'chinese-variant-leak': 'P2',
};
