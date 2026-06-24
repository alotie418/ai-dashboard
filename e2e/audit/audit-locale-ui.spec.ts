// UI-audit smoke harness (phase 1).
//
// Reuses the locale-matrix IPC boot (e2e/helpers/electronMock.ts: bootComboIPC) to
// drive the built SPA through the desktop IPC mock, then runs a fixed set of RELIABLE
// hard checks (raw i18n keys, K/M/万 money abbreviations, horizontal overflow, tab
// wrapping, modal scroll + reachable action buttons, AI-widget bounds, date-value
// format, US cross-regime tax terms). Findings are RECORDED (report.md + summary.json
// + screenshots), never fixed here — the spec passes as long as pages boot and scan.
//
// Scope (phase 1, smoke): UI = en/ja/ko/fr × acc = US/CN, pages dashboard/purchase/
// sales/finance/settings, modals add-purchase/add-sale/ai-widget. zh-CN/zh-TW purity,
// English-residue/Chinese-leak heuristics, OCR, and the full matrix are out of scope.

import { test, type Page } from '@playwright/test';
import * as path from 'node:path';
import { bootComboIPC, gotoApp, type ApiResponse } from '../helpers/electronMock';
import {
  findRawI18nKeys,
  findNumberAbbreviations,
  findCrossRegimeTax,
  findChineseVariantLeak,
  findEnglishResidueCandidates,
  findChineseLeakCandidates,
  classifyOverflow,
  classifyTabWrap,
  classifyButtonOffscreen,
  classifyModalNotScrollable,
  classifyHOverflow,
  classifyDateValue,
  guessSource,
  SEVERITY,
  type Box,
} from './rules';
import {
  ensureAuditDir,
  buildSummary,
  writeReport,
  AUDIT_DIR,
  type Finding,
  type Severity,
  type AuditScope,
} from './report';

// Candidate (heuristic English-residue / Chinese-leak) detection is OFF by default so
// the smoke baseline stays clean PASS. AUDIT_CANDIDATES=1 (npm run audit:locale-ui:candidates)
// turns it on; candidates are P2/P3 possibleFalsePositive and never affect merge advice.
const CANDIDATES = process.env.AUDIT_CANDIDATES === '1';
const AUDIT_MODE = CANDIDATES ? 'candidates' : process.env.AUDIT_MODE === 'full' ? 'full' : 'smoke';
// Candidate scan runs only on the CN accounting locale: English residue lives in the
// i18n JSON (t() path, default CN), while non-CN labels come from accountingLocaleConfig.
const CANDIDATE_ACC = 'CN';

const SMOKE_LANGS = ['en', 'ja', 'ko', 'fr'];
const SMOKE_ACCS = ['US', 'CN'];
const PAGES: { name: string; icon: string }[] = [
  { name: 'dashboard', icon: 'fa-th-large' },
  { name: 'purchase', icon: 'fa-file-import' },
  { name: 'sales', icon: 'fa-file-export' },
  { name: 'finance', icon: 'fa-wallet' },
  { name: 'settings', icon: 'fa-cog' },
];

// Candidate-only pages: scanned for English-residue / Chinese-leak (chrome text only,
// NO hard checks), in addition to the 5 smoke pages. These are the not-yet-reviewed
// pages where remaining visible residue is most likely. Only visited in candidate mode.
const CANDIDATE_EXTRA_PAGES: { name: string; icon: string }[] = [
  { name: 'accounts', icon: 'fa-handshake' },
  { name: 'inventory', icon: 'fa-search-dollar' },
  { name: 'transactions', icon: 'fa-exchange-alt' },
  { name: 'analysis', icon: 'fa-chart-pie' },
  { name: 'documents', icon: 'fa-file-contract' },
];

const SCOPE: AuditScope = {
  uiLanguages: SMOKE_LANGS,
  accountingLocales: SMOKE_ACCS,
  pages: PAGES.map((p) => p.name),
  modals: ['add-purchase', 'add-sale', 'ai-widget'],
};

// ── Finance needs valid /api/reports/generate + /api/balance-overview on mount, and
//    transactions/summary is an object; otherwise the page crashes. Shapes mirror
//    e2e/locale-matrix.spec.ts. Money values are full integers (no K/万 in the app). ──
const REPORT_MOCK = (acc: string) => ({
  locale: acc, period: { from: '2026-01-01', to: '2026-12-31', year: '2026' }, currency: '', reportTypes: [], warnings: [],
  incomeStatement: { salesRevenue: 100000, costOfSales: 60000, costOfGoodsSold: 60000, operatingExpenses: 0, grossProfit: 40000, adminExpense: 5000, operatingProfit: 35000, incomeTax: 6000, netProfit: 28000, netMargin: 28 },
  profitLoss: { revenue: 100000, costOfSales: 60000, costOfGoodsSold: 60000, operatingExpenses: 0, grossProfit: 40000, adminExpense: 5000, operatingProfit: 35000, incomeTax: 6000, netProfit: 28000, netMargin: 28 },
  scheduleC: { line1_grossReceipts: 100000, line7_grossIncome: 100000, line28_totalExpenses: 60000, line31_netProfit: 40000 },
});
const BALANCE_OVERVIEW_MOCK = (acc: string) => ({
  estimate: true, reportType: 'management_balance_overview', entityType: 'individual',
  period: { from: '2026-01-01', to: '2026-12-31' }, asOf: '2026-12-31', baseCurrency: acc === 'US' ? 'USD' : 'CNY',
  byCurrency: [{
    currency: acc === 'US' ? 'USD' : 'CNY',
    assets: { current: [{ key: 'cash', amount: 1200 }, { key: 'receivables', amount: 800 }, { key: 'inventory', amount: 0 }], nonCurrent: [{ key: 'fixedAssets', amount: 7000, meta: { originalValue: 8000, accumulatedDepreciation: 1000, netBookValue: 7000, estimate: true } }] },
    liabilities: { current: [{ key: 'payables', amount: 300 }, { key: 'borrowings', amount: 3500 }], nonCurrent: [{ key: 'borrowings', amount: 5000 }] },
    equity: [{ key: 'ownerCapital', amount: 20000 }, { key: 'retainedEarnings', amount: 10000 }],
    totals: { assets: 10000, liabilities: 8800, equity: 30000 }, balanceDifference: -28800, warnings: [],
  }],
  disclaimerKey: 'disclaimer.report', limitations: [], excludedNotes: [],
});

// AccountsPage reads receivables/payables as objects (data.agingBuckets['0-30'], …); the
// default lists mock returns [] (truthy) → [].agingBuckets crashes the page into the error
// boundary. Provide zeroed object shapes so the candidate sweep can render Accounts.
const RECEIVABLES_MOCK = { totalReceivable: 0, totalOverdue: 0, collectionRate: null, agingBuckets: { '0-30': 0, '31-60': 0, '61-90': 0, '90+': 0 }, topCustomers: [], details: [] };
const PAYABLES_MOCK = { totalPayable: 0, totalOverdue: 0, paymentRate: null, agingBuckets: { '0-30': 0, '31-60': 0, '61-90': 0, '90+': 0 }, topSuppliers: [], details: [] };

const AUDIT_API_RESPONSES = (acc: string): ApiResponse[] => [
  { match: '/api/transactions/summary', json: { income: { total: 0, count: 0 }, expense: { total: 0, count: 0 }, net: 0 } },
  { match: '/api/reports/generate', json: REPORT_MOCK(acc) },
  { match: '/api/balance-overview', json: BALANCE_OVERVIEW_MOCK(acc) },
  { match: '/api/receivables', json: RECEIVABLES_MOCK },
  { match: '/api/payables', json: PAYABLES_MOCK },
];

// ── Module-level accumulators (workers:1 → single process aggregates the whole run). ──
const findings: Finding[] = [];
const counters = { pagesScanned: 0, combos: 0, modals: 0 };

function addFinding(o: {
  type: string; ui: string; acc: string; page: string; modal?: string;
  message: string; snippet?: string; selector?: string; screenshot?: string;
  possibleFalsePositive?: boolean; severity?: Severity;
}): void {
  findings.push({
    severity: o.severity ?? SEVERITY[o.type] ?? 'P3',
    locale: o.ui,
    accountingLocale: o.acc,
    page: o.page,
    modal: o.modal,
    type: o.type,
    message: o.message,
    snippet: o.snippet,
    selector: o.selector,
    screenshot: o.screenshot,
    sourceFileGuess: guessSource(o.type, o.page, o.modal),
    possibleFalsePositive: o.possibleFalsePositive,
  });
}

function shotPaths(ui: string, name: string): { abs: string; rel: string } {
  const dir = ensureAuditDir(ui);
  return { abs: path.join(dir, `${name}.png`), rel: `${ui}/${name}.png` };
}

/** Visible text under a root, excluding inputs/code/kbd/links/scripts so shortcuts,
 *  model ids, URLs and API keys never reach the text rules. `extraSkipTags` adds more
 *  excluded tags — the candidate pass passes ['TD'] to skip table DATA cells (user data),
 *  keeping only chrome (labels/buttons/headers/th/options/headings). */
async function extractVisibleText(page: Page, rootSelector: string | null, extraSkipTags: string[] = []): Promise<string> {
  return page.evaluate(({ sel, extra }: { sel: string | null; extra: string[] }) => {
    const root: Element | null = sel ? document.querySelector(sel) : document.body;
    if (!root) return '';
    const SKIP = new Set(['INPUT', 'TEXTAREA', 'SELECT', 'CODE', 'KBD', 'PRE', 'SCRIPT', 'STYLE', 'NOSCRIPT', ...extra]);
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    const stop = root.parentElement;
    let out = '';
    let node = walker.nextNode();
    while (node) {
      let el: Element | null = node.parentElement;
      let skip = false;
      while (el && el !== stop) {
        if (SKIP.has(el.tagName)) { skip = true; break; }
        if (el.tagName === 'A' && el.getAttribute('href')) { skip = true; break; }
        el = el.parentElement;
      }
      if (!skip) out += (node.nodeValue || '') + ' ';
      node = walker.nextNode();
    }
    return out.replace(/\s+/g, ' ').trim();
  }, { sel: rootSelector, extra: extraSkipTags });
}

/** Phase-2 heuristic candidate rules (English residue + Chinese leak). Runs on chrome
 *  text only (table data cells excluded). All findings are possibleFalsePositive and
 *  never affect merge advice; fr residue is P3, ja Chinese-leak (simplified-only) is P3. */
function runCandidateRules(text: string, ctx: { ui: string; acc: string; page: string; modal?: string; screenshot?: string; selector?: string }): void {
  const base = { ui: ctx.ui, acc: ctx.acc, page: ctx.page, modal: ctx.modal, screenshot: ctx.screenshot, selector: ctx.selector, possibleFalsePositive: true };
  for (const c of findEnglishResidueCandidates(text, ctx.ui)) {
    const severity: Severity = ctx.ui === 'fr' ? 'P3' : 'P2';
    addFinding({ ...base, type: 'english-residue-candidate', severity, message: `possible English residue in ${ctx.ui} UI: "${c.token}"`, snippet: c.context });
  }
  for (const c of findChineseLeakCandidates(text, ctx.ui)) {
    const severity: Severity = ctx.ui === 'ja' ? 'P3' : 'P2';
    addFinding({ ...base, type: 'chinese-leak-candidate', severity, message: `possible Chinese leak in ${ctx.ui} UI: "${c.token}"`, snippet: c.context });
  }
}

/** Run the candidate pass (chrome text only) for a page/modal, gated on CANDIDATES + CN. */
async function scanCandidates(page: Page, ui: string, acc: string, pageName: string, rootSelector: string | null, modal: string | undefined, screenshot: string): Promise<void> {
  if (!CANDIDATES || acc !== CANDIDATE_ACC) return;
  const chrome = await extractVisibleText(page, rootSelector, ['TD']);
  runCandidateRules(chrome, { ui, acc, page: pageName, modal, screenshot, selector: rootSelector ?? 'body' });
}

/** Navigate a candidate-only page and run the candidate pass. Resilient by design:
 *  a short click timeout (no 120s hangs), and if a page crashes into the app error
 *  boundary (which removes <nav>), it is skipped + logged (not recorded as residue)
 *  and the app is rebooted so the remaining extra pages still get scanned. */
async function scanCandidatePage(page: Page, ui: string, acc: string, pageName: string, icon: string): Promise<void> {
  try {
    await page.locator(`nav i.${icon}`).first().click({ timeout: 6000 });
    await page.waitForTimeout(350);
  } catch (e: any) {
    console.warn(`[audit] candidate page ${pageName} (${ui}/${acc}) nav skipped: ${String(e?.message || e)}`);
    try { await gotoApp(page, ui); } catch { /* ignore */ }
    return;
  }
  // The app-level error boundary replaces the whole UI (including <nav>) on a render
  // crash — usually a mock-shape gap, not real residue. Skip + reboot so it doesn't
  // pollute candidates or break the next page.
  if ((await page.locator('nav').count()) === 0) {
    console.warn(`[audit] candidate page ${pageName} (${ui}/${acc}) crashed into error boundary — skipped + rebooting`);
    try { await gotoApp(page, ui); } catch { /* ignore */ }
    return;
  }
  const { abs, rel } = shotPaths(ui, pageName);
  await page.screenshot({ path: abs, fullPage: true });
  await scanCandidates(page, ui, acc, pageName, null, undefined, rel);
}

function runTextRules(text: string, ctx: { ui: string; acc: string; page: string; modal?: string; screenshot?: string; selector?: string }): void {
  const base = { ui: ctx.ui, acc: ctx.acc, page: ctx.page, modal: ctx.modal, screenshot: ctx.screenshot, selector: ctx.selector };
  for (const key of findRawI18nKeys(text)) {
    addFinding({ ...base, type: 'raw-i18n-key', message: `raw i18n key rendered in UI: ${key}`, snippet: key });
  }
  for (const ab of findNumberAbbreviations(text)) {
    addFinding({ ...base, type: 'number-abbreviation', message: `number abbreviation "${ab.match}" — show the full localized value (no K/k/M/万/萬)`, snippet: ab.context });
  }
  for (const cr of findCrossRegimeTax(text, ctx.ui, ctx.acc)) {
    const msg = cr.isEnglishResidue
      ? `US regime under ${ctx.ui}: English "Sales Tax" residue (should be localized) — ${cr.label}`
      : `US regime must not show cross-regime tax term — ${cr.label}`;
    addFinding({ ...base, type: 'cross-regime-tax', message: msg, snippet: cr.term, possibleFalsePositive: cr.isEnglishResidue });
  }
  // zh purity rule is wired but dormant: smoke runs no zh combos, so this never fires.
  for (const leak of findChineseVariantLeak(ctx.ui, text)) {
    addFinding({ ...base, type: 'chinese-variant-leak', message: `${leak.kind}: ${leak.char}`, snippet: leak.char });
  }
}

async function scanPage(page: Page, ui: string, acc: string, pageName: string, icon: string): Promise<void> {
  try {
    await page.locator(`nav i.${icon}`).first().click();
    await page.waitForTimeout(350);
  } catch (e: any) {
    addFinding({ type: 'navigation-failed', ui, acc, page: pageName, message: `could not navigate to ${pageName}: ${String(e?.message || e)}` });
    return;
  }
  counters.pagesScanned++;
  const { abs, rel } = shotPaths(ui, pageName);
  await page.screenshot({ path: abs, fullPage: true });

  const text = await extractVisibleText(page, null);
  runTextRules(text, { ui, acc, page: pageName, screenshot: rel, selector: 'body' });
  await scanCandidates(page, ui, acc, pageName, null, undefined, rel);

  // Page-level horizontal overflow (documentElement only → ignores inner scrollers).
  const ov = await page.evaluate(() => ({ scrollWidth: document.documentElement.scrollWidth, innerWidth: window.innerWidth }));
  if (classifyOverflow(ov.scrollWidth, ov.innerWidth)) {
    addFinding({ type: 'horizontal-overflow', ui, acc, page: pageName, screenshot: rel, message: `page overflows horizontally (scrollWidth ${ov.scrollWidth} > innerWidth ${ov.innerWidth})`, selector: 'document.documentElement' });
  }

  // date input value format (placeholder/calendar language is a known limitation).
  const dateVals: string[] = await page.evaluate(() =>
    Array.from(document.querySelectorAll('input[type="date"]')).map((i) => (i as HTMLInputElement).value),
  );
  dateVals.forEach((v, idx) => {
    if (classifyDateValue(v)) {
      addFinding({ type: 'date-value-format', ui, acc, page: pageName, screenshot: rel, message: `input[type=date] value "${v}" is not empty or YYYY-MM-DD`, selector: `input[type=date]#${idx}` });
    }
  });

  // Finance tab strip wrap check (generic classifier; reusable for other tab strips).
  if (pageName === 'finance') {
    const tab = await page.evaluate(() => {
      const balance = document.querySelector('[data-testid="finance-tab-balance"]') as HTMLElement | null;
      if (!balance || !balance.parentElement) return null;
      const strip = balance.parentElement;
      const btns = Array.from(strip.querySelectorAll('button')) as HTMLElement[];
      return { tops: btns.map((b) => b.offsetTop), count: btns.length };
    });
    if (tab && classifyTabWrap(tab.tops)) {
      addFinding({ type: 'tab-wrap', ui, acc, page: pageName, screenshot: rel, message: `finance tab strip wrapped onto multiple rows (button offsetTops ${tab.tops.join(',')})`, selector: '[data-testid=finance-tab-balance] (parent strip)' });
    }
  }
}

async function scanModal(page: Page, ui: string, acc: string, pageName: string, navIcon: string, modalName: string): Promise<void> {
  try {
    await page.locator(`nav i.${navIcon}`).first().click();
    await page.waitForTimeout(300);
    await page.locator('button:has(i.fa-plus)').first().click();
    await page.waitForTimeout(400);
  } catch (e: any) {
    addFinding({ type: 'navigation-failed', ui, acc, page: pageName, modal: modalName, message: `could not open ${modalName} modal: ${String(e?.message || e)}` });
    return;
  }
  counters.modals++;
  const { abs, rel } = shotPaths(ui, `${pageName}__${modalName}`);
  await page.screenshot({ path: abs, fullPage: true });

  const text = await extractVisibleText(page, '.fixed.inset-0');
  runTextRules(text, { ui, acc, page: pageName, modal: modalName, screenshot: rel, selector: '.fixed.inset-0' });
  await scanCandidates(page, ui, acc, pageName, '.fixed.inset-0', modalName, rel);

  const geo = await page.evaluate(() => {
    const overlay = document.querySelector('.fixed.inset-0');
    if (!overlay) return null;
    const form = overlay.querySelector('form') as HTMLElement | null;
    const submit = overlay.querySelector('button[type="submit"]') as HTMLElement | null;
    // The footer Cancel is the type="button" sibling of Submit in the same footer row.
    // Scoping to that row avoids matching in-form type="button" controls (OCR scan,
    // product picker) or the header close-X, which would measure the wrong element.
    const footer = submit ? (submit.parentElement as HTMLElement | null) : null;
    const cancel = (footer ? footer.querySelector('button[type="button"]') : null) as HTMLElement | null;
    const card = (form?.parentElement ?? overlay.querySelector('.relative')) as HTMLElement | null;
    // The footer action buttons live INSIDE the overflow-y-auto form. Simulate the
    // user scrolling that area to its end so the buttons are brought into view; only
    // flag them as unreachable if they are STILL offscreen after scrolling (e.g. the
    // modal card itself overflows the viewport with no way to reach them).
    if (form) form.scrollTop = form.scrollHeight;
    const box = (e: HTMLElement | null): Box | null => {
      if (!e) return null;
      const r = e.getBoundingClientRect();
      return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
    };
    const cs = form ? getComputedStyle(form) : null;
    return {
      vw: window.innerWidth, vh: window.innerHeight,
      submit: box(submit), cancel: box(cancel),
      formOverflowY: cs ? cs.overflowY : '',
      formScrollH: form ? form.scrollHeight : 0,
      formClientH: form ? form.clientHeight : 0,
      cardScrollW: card ? card.scrollWidth : 0,
      cardClientW: card ? card.clientWidth : 0,
      docScrollW: document.documentElement.scrollWidth,
    };
  });
  if (geo) {
    if (geo.submit && classifyButtonOffscreen(geo.submit, geo.vw, geo.vh)) {
      addFinding({ type: 'modal-button-offscreen', ui, acc, page: pageName, modal: modalName, screenshot: rel, message: `confirm button is outside the viewport (bottom ${Math.round(geo.submit.bottom)} vs vh ${geo.vh})`, selector: '.fixed.inset-0 button[type=submit]' });
    }
    if (geo.cancel && classifyButtonOffscreen(geo.cancel, geo.vw, geo.vh)) {
      addFinding({ type: 'modal-button-offscreen', ui, acc, page: pageName, modal: modalName, screenshot: rel, message: `cancel button is outside the viewport (bottom ${Math.round(geo.cancel.bottom)} vs vh ${geo.vh})`, selector: '.fixed.inset-0 button[type=button]' });
    }
    if (classifyModalNotScrollable(geo.formScrollH, geo.formClientH, geo.formOverflowY)) {
      addFinding({ type: 'modal-not-scrollable', ui, acc, page: pageName, modal: modalName, screenshot: rel, message: `modal content overflows (${geo.formScrollH}>${geo.formClientH}) but overflow-y is "${geo.formOverflowY}"`, selector: '.fixed.inset-0 form' });
    }
    if (classifyHOverflow(geo.cardScrollW, geo.cardClientW)) {
      addFinding({ type: 'modal-horizontal-overflow', ui, acc, page: pageName, modal: modalName, screenshot: rel, message: `modal card overflows horizontally (${geo.cardScrollW}>${geo.cardClientW})`, selector: '.fixed.inset-0 .relative' });
    }
    if (classifyOverflow(geo.docScrollW, geo.vw)) {
      addFinding({ type: 'modal-horizontal-overflow', ui, acc, page: pageName, modal: modalName, screenshot: rel, message: `open modal pushes the page into horizontal scroll (docScrollWidth ${geo.docScrollW} > vw ${geo.vw})`, selector: 'document.documentElement' });
    }
  }

  // Close the modal (fa-times). Best-effort: failure to close is non-fatal.
  try {
    await page.locator('.fixed.inset-0 button:has(i.fa-times)').first().click();
    await page.waitForTimeout(200);
  } catch { /* ignore */ }
}

async function scanAiWidget(page: Page, ui: string, acc: string): Promise<void> {
  // The floating widget is hidden on the assistant page; we are on a non-assistant page.
  try {
    await page.locator('.fixed.bottom-8.right-8 button').first().click();
    await page.waitForTimeout(400);
  } catch (e: any) {
    addFinding({ type: 'navigation-failed', ui, acc, page: 'settings', modal: 'ai-widget', message: `could not open AI widget: ${String(e?.message || e)}` });
    return;
  }
  counters.modals++;
  const { abs, rel } = shotPaths(ui, `settings__ai-widget`);
  await page.screenshot({ path: abs, fullPage: true });

  const geo = await page.evaluate(() => {
    const root = document.querySelector('.fixed.bottom-8.right-8');
    if (!root) return null;
    const panel = (root.querySelector('div.glass-modal') || root.querySelector('[class*="glass-modal"]')) as HTMLElement | null;
    const docScrollW = document.documentElement.scrollWidth;
    if (!panel) return { vw: window.innerWidth, vh: window.innerHeight, panel: null as Box | null, docScrollW };
    const r = panel.getBoundingClientRect();
    return { vw: window.innerWidth, vh: window.innerHeight, panel: { top: r.top, bottom: r.bottom, left: r.left, right: r.right } as Box, docScrollW };
  });
  if (geo && geo.panel) {
    if (classifyButtonOffscreen(geo.panel, geo.vw, geo.vh)) {
      addFinding({ type: 'ai-widget-out-of-bounds', ui, acc, page: 'settings', modal: 'ai-widget', screenshot: rel, message: `AI widget panel extends past the viewport (right ${Math.round(geo.panel.right)}/vw ${geo.vw}, bottom ${Math.round(geo.panel.bottom)}/vh ${geo.vh})`, selector: '.fixed.bottom-8.right-8 .glass-modal' });
    }
    if (classifyOverflow(geo.docScrollW, geo.vw)) {
      addFinding({ type: 'ai-widget-out-of-bounds', ui, acc, page: 'settings', modal: 'ai-widget', screenshot: rel, message: `open AI widget pushes the page into horizontal scroll (docScrollWidth ${geo.docScrollW} > vw ${geo.vw})`, selector: 'document.documentElement' });
    }
  }
  // Close the widget (toggle again). Best-effort.
  try {
    await page.locator('.fixed.bottom-8.right-8 button').first().click();
    await page.waitForTimeout(150);
  } catch { /* ignore */ }
}

for (const acc of SMOKE_ACCS) {
  for (const ui of SMOKE_LANGS) {
    test(`audit ui=${ui} acc=${acc}`, async ({ page }) => {
      counters.combos++;
      try {
        await bootComboIPC(page, ui, acc, { apiResponses: AUDIT_API_RESPONSES(acc) });
        await page.waitForTimeout(400);
      } catch (e: any) {
        const { abs, rel } = shotPaths(ui, 'boot-failed');
        try { await page.screenshot({ path: abs, fullPage: true }); } catch { /* ignore */ }
        addFinding({ type: 'page-boot-failed', ui, acc, page: 'dashboard', screenshot: rel, message: `app failed to boot: ${String(e?.message || e)}` });
        return;
      }
      for (const pg of PAGES) {
        await scanPage(page, ui, acc, pg.name, pg.icon);
      }
      await scanModal(page, ui, acc, 'purchase', 'fa-file-import', 'add-purchase');
      await scanModal(page, ui, acc, 'sales', 'fa-file-export', 'add-sale');
      // Re-anchor on a non-assistant page, then exercise the floating AI widget.
      await page.locator('nav i.fa-cog').first().click();
      await page.waitForTimeout(250);
      await scanAiWidget(page, ui, acc);
      // Candidate-only: sweep the not-yet-reviewed pages for residue (CN × 4 langs).
      if (CANDIDATES && acc === CANDIDATE_ACC) {
        for (const pg of CANDIDATE_EXTRA_PAGES) {
          await scanCandidatePage(page, ui, acc, pg.name, pg.icon);
        }
      }
    });
  }
}

test.afterAll(async () => {
  const summary = buildSummary(findings, SCOPE, AUDIT_MODE, counters);
  const { reportPath, summaryPath } = writeReport(summary);
  const c = summary.counts;
  const lines = [
    '',
    '──────────────────────────────────────────────',
    ` UI Audit (${AUDIT_MODE}) — ${summary.timestamp}`,
    '──────────────────────────────────────────────',
    ` Pages scanned : ${c.pagesScanned}`,
    ` Combos        : ${c.combos}  (${SCOPE.uiLanguages.join('/')} × ${SCOPE.accountingLocales.join('/')})`,
    ` Modals        : ${c.modals}`,
    ` Findings(hard): ${c.findings}   P0=${c.P0} P1=${c.P1} P2=${c.P2} P3=${c.P3}`,
    ` Hard fail     : ${c.hardFail}`,
    ` Candidates    : ${c.candidates}${CANDIDATES ? '' : ' (pass off — run audit:locale-ui:candidates)'}`,
    ` Merge advice  : ${summary.mergeAdvice}`,
    '──────────────────────────────────────────────',
    ` report.md   : ${reportPath}`,
    ` summary.json: ${summaryPath}`,
    ` artifacts   : ${AUDIT_DIR}/`,
    '──────────────────────────────────────────────',
    '',
  ];
  console.log(lines.join('\n'));
});
