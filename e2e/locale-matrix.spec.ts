import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

// ───────────────────────────────────────────────────────────────────────────
// Page-level 6×6 = 36-combination display acceptance.
//   uiLanguage decides display language ONLY; accountingLocale decides the
//   accounting regime / tax wording ONLY. They must never cross-contaminate.
//   The SPA is served by `vite preview`; /auth + /api are mocked per combo so
//   the regime tax labels (client-side getTaxLabel) render without a backend.
// ───────────────────────────────────────────────────────────────────────────

const UI_LANGUAGES = ['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr'] as const;
const ACCOUNTING_LOCALES = ['CN', 'US', 'JP', 'EU', 'KR', 'TW'] as const;

// (3)-(8) regime cross-contamination: words an accountingLocale must NEVER show.
const FORBIDDEN_BY_LOCALE: Record<string, string[]> = {
  CN: ['营业税', '營業稅', 'Sales Tax', '消费税', '消費稅', '统一发票', '統一發票'],
  US: ['增值税', '增值稅', '营业税', '營業稅', '进项税额', '進項稅額', '销项税额', '銷項稅額', '消费税', '消費稅'],
  JP: ['增值税', '增值稅', '营业税', '營業稅', 'Sales Tax', '销售税', '銷售稅'],
  EU: ['营业税', '營業稅', '消费税', '消費稅', 'Sales Tax', '销售税', '銷售稅', '已认证进项税额', '已認證進項稅額'],
  KR: ['营业税', '營業稅', '消费税', '消費稅', 'Sales Tax', '销售税', '銷售稅', '已认证进项税额', '已認證進項稅額'],
  TW: ['增值税', '增值稅', '应交增值税', '應交增值稅', '已认证', '已認證'],
};

// (1)/(2) the spec's explicit "must not appear" word lists.
const ZH_CN_FORBIDDEN_WORDS = ['資料', '採購', '銷售', '進項', '銷項', '簡報', '支援', '統計', '應納', '營業'];
const ZH_TW_FORBIDDEN_WORDS = ['资料', '采购', '销售', '进项', '销项', '简报', '支持', '统计', '应纳', '营业'];

// Variant-only characters (exclude chars common to both scripts such as 售/支/收).
const SIMP_ONLY = '务报单发资应进销项额总户营关转库类数据显实现产业会计帐账团价风财购费贵质软输边过还这远连选录钱错门问间队页题验证设论说请读谢识译试详语调谈课规视见觉访评诺贸贺贴赞跃较递邮钟铁银锁难韩顺颗颜饭饮馆骤东车书长岁两广严丰临为乌乐习乡买乱争亏阳';
const TRAD_ONLY = '務報單發資應進銷項額總戶營關轉庫類數據顯實現產業會計帳賬團價風財購費貴質軟輸邊過還這遠連選錄錢錯門問間隊頁題驗證設論說請讀謝識譯試詳語調談課規視見覺訪評諾貿賀貼讚躍較遞郵鐘鐵銀鎖難韓順顆顏飯飲館驟東車書長歲兩廣嚴豐臨為烏樂習鄉買亂爭虧陽';

const SCREENSHOT_DIR = path.join('test-results', 'locale-matrix');

const SETTINGS = (acc: string) => ({
  accounting_locale: acc,
  product_unit: 'ton',
  company_name: 'Test Co',
  legal_person: 'Tester',
  vat_rate: acc === 'TW' ? '5%' : acc === 'US' ? '7%' : '13%',
  industry: 'Trade',
});

const DASHBOARD = (acc: string) => ({
  locale: acc,
  metrics: { inventoryTons: 0, purchaseTotalTons: 0, purchaseTotalAmount: 0, salesTotalTons: 0, salesTotalAmount: 0, avgCostPerTon: 0 },
  monthlyPerformance: [],
  financialStatement: { salesRevenue: 0, costOfSales: 0, taxSurcharge: 0, adminExpense: 0, incomeTax: 0, shippingFee: 0, grossProfit: 0, grossMargin: 0, netProfit: 0, netMargin: 0 },
  vatStatistics: { cumulativeInput: 0, cumulativeOutput: 0, certifiedInput: 0, invoicedOutput: 0, estimatedPayable: 0 },
  taxInclusiveSummary: { purchaseTotal: 0, salesTotal: 0, difference: 0 },
  inventory: { inStockCount: 1, totalInventoryCost: 100, details: [{ product_id: 'p1', name: 'Item-A', unit: 'piece', qtyOnHand: 10, unitCost: 10, lineCost: 100 }] },
});

type Failure = { ui: string; acc: string; page: string; word: string; rule: string; snippet: string; screenshot: string };
const failures: Failure[] = [];

function snippetAround(text: string, word: string): string {
  const i = text.indexOf(word);
  if (i < 0) return '';
  return text.slice(Math.max(0, i - 25), i + word.length + 25).replace(/\s+/g, ' ').trim();
}

for (const acc of ACCOUNTING_LOCALES) {
  for (const ui of UI_LANGUAGES) {
    test(`ui=${ui} acc=${acc}`, async ({ page }) => {
      // ── mock auth + API so the SPA boots and resolves this accountingLocale ──
      await page.route('**/auth/check', (r) => r.fulfill({ json: { authenticated: true } }));
      await page.route('**/auth/**', (r) => r.fulfill({ json: { authenticated: true } }));
      await page.route('**/api/**', (route) => {
        const url = route.request().url();
        if (url.includes('/api/settings')) return route.fulfill({ json: SETTINGS(acc) });
        if (url.includes('/api/dashboard')) return route.fulfill({ json: DASHBOARD(acc) });
        if (/\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|documents|reports\/types)/.test(url)) {
          return route.fulfill({ json: [] });
        }
        return route.fulfill({ json: {} }); // catch-all → empty object
      });
      // set UI language before the app boots (i18n reads localStorage 'sololedger-lang')
      await page.addInitScript((l) => { try { localStorage.setItem('sololedger-lang', l as string); } catch { /* ignore */ } }, ui);

      await page.goto('/', { waitUntil: 'domcontentloaded' });
      // sidebar nav is the anchor that the dashboard has rendered
      await page.waitForSelector('nav', { timeout: 20_000 });
      await page.waitForTimeout(500);

      fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
      const shot = path.join(SCREENSHOT_DIR, `${ui}__${acc}.png`);
      await page.screenshot({ path: shot, fullPage: true });

      const text = await page.locator('body').innerText();
      const local: Failure[] = [];
      const flag = (word: string, rule: string) =>
        local.push({ ui, acc, page: 'dashboard', word, rule, snippet: snippetAround(text, word), screenshot: shot });

      // (3)-(8) regime口径
      for (const w of FORBIDDEN_BY_LOCALE[acc]) if (text.includes(w)) flag(w, `${acc} regime must not show "${w}"`);
      // (1)/(2) explicit language word lists + variant-char sweep
      if (ui === 'zh-CN') {
        for (const w of ZH_CN_FORBIDDEN_WORDS) if (text.includes(w)) flag(w, 'zh-CN UI must be Simplified (traditional word)');
        for (const c of TRAD_ONLY) if (text.includes(c)) { flag(c, 'zh-CN UI must be Simplified (traditional char)'); break; }
      }
      if (ui === 'zh-TW') {
        for (const w of ZH_TW_FORBIDDEN_WORDS) if (text.includes(w)) flag(w, 'zh-TW UI must be Traditional (simplified word)');
        for (const c of SIMP_ONLY) if (text.includes(c)) { flag(c, 'zh-TW UI must be Traditional (simplified char)'); break; }
      }

      for (const f of local) {
        failures.push(f);
        console.error(
          `FAIL\n  uiLanguage: ${f.ui}\n  accountingLocale: ${f.acc}\n  page: ${f.page}\n  actual: "${f.snippet}"\n  forbidden: ${f.word}\n  expected: ${f.rule}\n  screenshot: ${f.screenshot}`,
        );
      }
      expect(local, local.map((f) => `[ui=${ui} acc=${acc}] "${f.word}" — ${f.rule}`).join('\n')).toEqual([]);
    });
  }
}

// ── Settings → Products/Services sub-tab opens & renders across all 36 combos ──
// Navigation uses stable, language-independent icons (sidebar fa-cog → settings;
// sub-tab fa-box → products), so no fragile cross-language text selectors and no UI change.
async function bootCombo(page: import('@playwright/test').Page, ui: string, acc: string) {
  await page.route('**/auth/check', (r) => r.fulfill({ json: { authenticated: true } }));
  await page.route('**/auth/**', (r) => r.fulfill({ json: { authenticated: true } }));
  await page.route('**/api/**', (route) => {
    const url = route.request().url();
    if (url.includes('/api/settings')) return route.fulfill({ json: SETTINGS(acc) });
    if (url.includes('/api/dashboard')) return route.fulfill({ json: DASHBOARD(acc) });
    if (/\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|documents|reports\/types)/.test(url)) {
      return route.fulfill({ json: [] });
    }
    return route.fulfill({ json: {} });
  });
  await page.addInitScript((l) => { try { localStorage.setItem('sololedger-lang', l as string); } catch { /* ignore */ } }, ui);
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('nav', { timeout: 20_000 });
}

test.describe('settings → products/services tab', () => {
  for (const acc of ACCOUNTING_LOCALES) {
    for (const ui of UI_LANGUAGES) {
      test(`products-tab ui=${ui} acc=${acc}`, async ({ page }) => {
        await bootCombo(page, ui, acc);
        const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
        const expectedTitle: string = loc.products.title;
        const expectedEmpty: string = loc.products.empty;

        // (1)(2) open Settings via sidebar fa-cog, then the Products/Services sub-tab via fa-box
        await page.locator('i.fa-cog').first().click();
        await page.locator('button:has(i.fa-box)').click();

        // (3) the products title renders the resolved translation (proves the key is not a raw leak)
        await expect(page.getByRole('heading', { name: expectedTitle })).toBeVisible({ timeout: 10_000 });

        // (4) empty state renders — auto-wait, since it only appears after the (empty)
        //     products list resolves (the title shows earlier, outside the loading gate)
        await expect(page.getByText(expectedEmpty)).toBeVisible({ timeout: 10_000 });

        // (5) no raw products.* / settings.nav.* i18n key leaked into the rendered UI
        const body = await page.locator('body').innerText();
        expect(body, `[ui=${ui} acc=${acc}] raw i18n key leaked`).not.toMatch(/products\.[a-zA-Z]|settings\.nav\.[a-zA-Z]/);
      });
    }
  }
});

// ── Phase 2: purchase add-record modal exposes the product/service picker ──
// The picker is uiLanguage-only (regime-neutral), so one accountingLocale × 6 UI langs
// is the meaningful axis. Navigation uses stable icons (sidebar fa-file-import → 采购页;
// new-record button fa-plus → modal). No UI change for the test.
test.describe('purchase modal → product picker (Phase 2)', () => {
  const acc = 'CN';
  for (const ui of UI_LANGUAGES) {
    test(`purchase-picker ui=${ui}`, async ({ page }) => {
      await bootCombo(page, ui, acc);
      const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
      const selectLabel: string = loc.products.selectLabel;
      const unassigned: string = loc.products.unassigned;

      await page.locator('i.fa-file-import').first().click();
      await page.locator('button:has(i.fa-plus)').first().click();

      // picker label renders the resolved translation (not a raw key)
      await expect(page.getByText(selectLabel, { exact: false }).first()).toBeVisible({ timeout: 10_000 });
      // the "unassigned" option is present in the picker
      expect(await page.locator('option').filter({ hasText: unassigned }).count()).toBeGreaterThan(0);
      // no raw products.* picker key leaked
      const body = await page.locator('body').innerText();
      expect(body, `[ui=${ui}] raw picker key leaked`).not.toMatch(/products\.(selectLabel|unassigned)/);
    });
  }
});

// ── Settings → Data Backup sub-tab opens & renders across all 36 combos ──
// uiLanguage-only feature. The preview build has no window.electronAPI, so the
// section must render the desktop-only notice and NOT crash. Navigation uses
// stable icons (sidebar fa-cog → settings; sub-tab fa-box-archive → data backup).
test.describe('settings → data backup tab', () => {
  for (const acc of ACCOUNTING_LOCALES) {
    for (const ui of UI_LANGUAGES) {
      test(`data-backup-tab ui=${ui} acc=${acc}`, async ({ page }) => {
        await bootCombo(page, ui, acc);
        const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
        const expectedTitle: string = loc.settings.dataBackup.title;
        const expectedDesktopOnly: string = loc.settings.dataBackup.desktopOnly;

        await page.locator('i.fa-cog').first().click();
        await page.locator('button:has(i.fa-box-archive)').click();

        // (1) title heading renders the resolved translation (proves the key is not a raw leak)
        await expect(page.getByRole('heading', { name: expectedTitle })).toBeVisible({ timeout: 10_000 });
        // (2) web/preview build has no electronAPI → desktop-only notice shown, app does not crash
        await expect(page.getByText(expectedDesktopOnly)).toBeVisible({ timeout: 10_000 });
        // (3) no raw settings.dataBackup.* / settings.nav.* key leaked into the rendered UI
        const body = await page.locator('body').innerText();
        expect(body, `[ui=${ui} acc=${acc}] raw i18n key leaked`).not.toMatch(/settings\.dataBackup\.[a-zA-Z]|settings\.nav\.[a-zA-Z]/);
      });
    }
  }
});

// ── Data Backup happy path with a mocked desktop electronAPI ──
// Inject an isElectron stub BEFORE boot (api.ts routes api:request through IPC when
// isElectron), so the section runs its real backup/restore/relaunch flow against canned
// IPC results: backup shows the saved path; restore is gated by a two-step overwrite
// confirm, then shows the auto-backup path + restart prompt. One ui×acc combo suffices
// (the feature is regime-neutral; the 36-combo render is covered above).
test('data backup → mock electronAPI: backup success + restore confirm + success', async ({ page }) => {
  const ui = 'zh-CN';
  const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
  const db = loc.settings.dataBackup;

  await page.addInitScript(({ settings, dashboard }) => {
    const lists = /\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|documents|reports\/types)/;
    (window as any).electronAPI = {
      isElectron: true,
      platform: 'darwin',
      buildTarget: 'dmg',
      invoke: (channel: string, payload: any) => {
        if (channel === 'app:exportDb') return Promise.resolve({ ok: true, path: '/Users/test/Backups/sololedger-backup-2026-06-10.db' });
        if (channel === 'app:importDb') return Promise.resolve({ ok: true, restoredFrom: '/Users/test/Backups/restore.db', autoBackupPath: '/Users/test/Backups/auto-before-restore.db' });
        if (channel === 'app:relaunch') return Promise.resolve({ ok: true, devMode: true });
        // hasAny=true so the desktop boot skips the BYOK onboarding wizard and renders the app (nav)
        if (channel === 'providers:hasAny') return Promise.resolve(true);
        if (channel === 'providers:list') return Promise.resolve([]);
        if (channel === 'api:request') {
          const p = (payload && payload.path) || '';
          if (p.includes('/api/settings')) return Promise.resolve(settings);
          if (p.includes('/api/dashboard')) return Promise.resolve(dashboard);
          if (lists.test(p)) return Promise.resolve([]);
          return Promise.resolve({});
        }
        return Promise.resolve({});
      },
    };
  }, { settings: SETTINGS('CN'), dashboard: DASHBOARD('CN') });

  await bootCombo(page, ui, 'CN');
  await page.locator('i.fa-cog').first().click();
  await page.locator('button:has(i.fa-box-archive)').click();

  // desktop mode → no desktop-only banner
  await expect(page.getByText(db.desktopOnly)).toHaveCount(0);

  // backup → saved path shown
  await page.getByRole('button', { name: db.backupButton }).click();
  await expect(page.getByText(/sololedger-backup-2026-06-10\.db/)).toBeVisible({ timeout: 10_000 });

  // restore → two-step confirm exposes the overwrite/restart warning
  await page.getByRole('button', { name: db.restoreButton }).click();
  await expect(page.getByText(db.restoreWarning)).toBeVisible({ timeout: 10_000 });

  // confirm → restore success + auto-backup path + restart prompt + restart button
  await page.getByRole('button', { name: db.restoreConfirm }).click();
  await expect(page.getByText(/auto-before-restore\.db/)).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText(db.restartRequired)).toBeVisible();
  await expect(page.getByRole('button', { name: db.restartNow })).toBeVisible();

  // dev-mode relaunch: clicking restart shows the manual-restart notice (no process kill / white screen)
  await page.getByRole('button', { name: db.restartNow }).click();
  await expect(page.getByText(db.devModeRestart)).toBeVisible({ timeout: 10_000 });
});

// ── Finance → Export PDF button (uiLanguage-only feature). The finance page renders
//    a P&L from /api/reports/generate, so a valid report payload is mocked (empty {}
//    would crash it). Navigation via the sidebar fa-wallet icon. ──
const REPORT_MOCK = (acc: string) => ({
  locale: acc, period: { from: '2026-01-01', to: '2026-12-31', year: '2026' }, currency: '', reportTypes: [], warnings: [],
  incomeStatement: { salesRevenue: 100000, costOfSales: 60000, grossProfit: 40000, adminExpense: 5000, operatingProfit: 35000, incomeTax: 6000, netProfit: 28000, netMargin: 28 },
  profitLoss: { revenue: 100000, costOfSales: 60000, grossProfit: 40000, adminExpense: 5000, operatingProfit: 35000, incomeTax: 6000, netProfit: 28000, netMargin: 28 },
  scheduleC: { line1_grossReceipts: 100000, line7_grossIncome: 100000, line28_totalExpenses: 60000, line31_netProfit: 40000 },
});

async function bootFinance(page: import('@playwright/test').Page, ui: string, acc: string) {
  await page.route('**/auth/check', (r) => r.fulfill({ json: { authenticated: true } }));
  await page.route('**/auth/**', (r) => r.fulfill({ json: { authenticated: true } }));
  await page.route('**/api/**', (route) => {
    const url = route.request().url();
    if (url.includes('/api/settings')) return route.fulfill({ json: SETTINGS(acc) });
    if (url.includes('/api/dashboard')) return route.fulfill({ json: DASHBOARD(acc) });
    if (url.includes('/api/reports/generate')) return route.fulfill({ json: REPORT_MOCK(acc) });
    if (/\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|documents|reports\/types)/.test(url)) {
      return route.fulfill({ json: [] });
    }
    return route.fulfill({ json: {} });
  });
  await page.addInitScript((l) => { try { localStorage.setItem('sololedger-lang', l as string); } catch { /* ignore */ } }, ui);
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('nav', { timeout: 20_000 });
}

test.describe('finance → export PDF', () => {
  const FINANCE_COMBOS = [{ ui: 'zh-CN', acc: 'CN' }, { ui: 'en', acc: 'US' }, { ui: 'ja', acc: 'JP' }];
  for (const { ui, acc } of FINANCE_COMBOS) {
    test(`export-pdf button ui=${ui} acc=${acc}`, async ({ page }) => {
      await bootFinance(page, ui, acc);
      const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
      await page.locator('i.fa-wallet').first().click(); // → finance page
      const btn = page.locator('button:has(i.fa-file-pdf)');
      await expect(btn).toBeVisible({ timeout: 10_000 });
      // report tab labels must follow UI language (regression lock: ja/ko/fr Balance Sheet / Cash Flow)
      await expect(page.getByRole('button', { name: loc.finance.tabBalance })).toBeVisible();
      await expect(page.getByRole('button', { name: loc.finance.tabCashflow })).toBeVisible();
      // web/preview build has no electronAPI → clicking shows the desktop-only notice, no crash
      await btn.click();
      await expect(page.getByText(loc.finance.pdfDesktopOnly)).toBeVisible({ timeout: 10_000 });
      // no raw finance.pdf* / finance.exportPdf key leaked
      const body = await page.locator('body').innerText();
      expect(body, `[ui=${ui} acc=${acc}] raw finance.pdf key`).not.toMatch(/finance\.pdf[A-Za-z]|finance\.exportPdf/);
    });
  }

  test('export-pdf → mock electronAPI success shows saved path', async ({ page }) => {
    const ui = 'zh-CN';
    await page.addInitScript(() => {
      (window as any).electronAPI = {
        isElectron: true, platform: 'darwin', buildTarget: 'dmg',
        invoke: (channel: string, payload: any) => {
          if (channel === 'app:exportReportPdf') return Promise.resolve({ ok: true, path: '/Users/test/Reports/SoloLedger-CN-pl-2026.pdf' });
          if (channel === 'providers:hasAny') return Promise.resolve(true);
          if (channel === 'api:request') {
            const p = (payload && payload.path) || '';
            if (p.includes('/api/settings')) return Promise.resolve({ accounting_locale: 'CN', company_name: 'Test Co' });
            if (p.includes('/api/dashboard')) return Promise.resolve({ locale: 'CN', metrics: {}, financialStatement: { salesRevenue: 100000, costOfSales: 60000, taxSurcharge: 0, shippingFee: 0, adminExpense: 0, incomeTax: 0, grossProfit: 40000, grossMargin: 40, netProfit: 40000, netMargin: 40 }, monthlyPerformance: [], vatStatistics: {}, taxInclusiveSummary: {}, inventory: { inStockCount: 0, totalInventoryCost: 0, details: [] } });
            if (p.includes('/api/reports/generate')) return Promise.resolve({ locale: 'CN', period: { from: '', to: '', year: '2026' }, currency: '', reportTypes: [], warnings: [], incomeStatement: { salesRevenue: 100000, costOfSales: 60000, grossProfit: 40000, adminExpense: 5000, incomeTax: 6000, netProfit: 28000, netMargin: 28 } });
            return Promise.resolve(/categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|reports\/types/.test(p) ? [] : {});
          }
          return Promise.resolve({});
        },
      };
    });
    await page.route('**/auth/**', (r) => r.fulfill({ json: { authenticated: true } }));
    await page.addInitScript((l) => { try { localStorage.setItem('sololedger-lang', l as string); } catch { /* ignore */ } }, ui);
    await page.goto('/', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('nav', { timeout: 20_000 });
    await page.locator('i.fa-wallet').first().click();
    await page.locator('button:has(i.fa-file-pdf)').click();
    await expect(page.getByText(/SoloLedger-CN-pl-2026\.pdf/)).toBeVisible({ timeout: 10_000 });
  });
});

// ── Business Documents page renders across all 36 combos (Phase A) ──
// Desktop-only feature: the web/preview build has no window.electronAPI (and the
// deployed web mode has no /api/documents routes), so the page must render its title
// + the desktop-only notice and NOT crash / NOT fetch. Navigation uses the sidebar
// fa-file-contract icon, scoped to <nav> (NavItem is a <div>, not a <button>).
test.describe('business documents page', () => {
  for (const acc of ACCOUNTING_LOCALES) {
    for (const ui of UI_LANGUAGES) {
      test(`documents-page ui=${ui} acc=${acc}`, async ({ page }) => {
        await bootCombo(page, ui, acc);
        const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

        await page.locator('nav i.fa-file-contract').first().click();

        // (1) title renders the resolved translation (proves the key is not a raw leak)
        await expect(page.getByRole('heading', { name: loc.documents.title }).first()).toBeVisible({ timeout: 10_000 });
        // (2) web/preview build → desktop-only notice shown, app does not crash
        await expect(page.getByText(loc.documents.desktopOnly)).toBeVisible({ timeout: 10_000 });
        // (3) no raw documents.* / nav.documents key leaked into the rendered UI
        const body = await page.locator('body').innerText();
        expect(body, `[ui=${ui} acc=${acc}] raw documents key leaked`).not.toMatch(/documents\.[a-zA-Z]|nav\.documents|headerTitle\.documents/);
      });
    }
  }
});

// ── AI Assistant standalone page renders across all 36 combos (R2a) ──
// The standalone page reuses the floating widget's ChatPanel and shares the same
// AssistantProvider session. It is NOT desktop-only (chat works in web mode too via
// apiFetch), so unlike the documents page it must render the chat shell itself: the
// header title + empty-state welcome card + input box — with no raw chat.* / nav.assistant
// key leaking. Navigation uses the sidebar fa-comments icon, scoped to <nav> (NavItem is a
// <div>, not a <button>); the floating widget uses "AI"/fa-robot, never fa-comments.
test.describe('ai assistant page', () => {
  for (const acc of ACCOUNTING_LOCALES) {
    for (const ui of UI_LANGUAGES) {
      test(`assistant-page ui=${ui} acc=${acc}`, async ({ page }) => {
        await bootCombo(page, ui, acc);
        const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

        await page.locator('nav i.fa-comments').first().click();

        // (1) header title renders the resolved translation (proves the key is not a raw leak)
        await expect(page.getByRole('heading', { name: loc.headerTitle.assistant }).first()).toBeVisible({ timeout: 10_000 });
        // (2) the page's ChatPanel is mounted: empty-state welcome + input placeholder render
        await expect(page.getByText(loc.chat.welcome).first()).toBeVisible({ timeout: 10_000 });
        await expect(page.getByPlaceholder(loc.chat.placeholder).first()).toBeVisible({ timeout: 10_000 });
        // (3) no raw chat.* / nav.assistant / headerTitle.assistant key leaked into the rendered UI
        const body = await page.locator('body').innerText();
        expect(body, `[ui=${ui} acc=${acc}] raw assistant key leaked`).not.toMatch(/chat\.[a-zA-Z]|nav\.assistant|headerTitle\.assistant/);
      });
    }
  }
});

// ── AI assistant read-only tool trace (R2b-1) — mocked agent-chat happy path ──
// The assistant page now sends through aiAgentChat (POST /api/ai/agent-chat). We mock that
// endpoint (registered after bootCombo → takes precedence) to return a deterministic answer +
// a toolTrace, then assert the chat renders BOTH the final answer AND the localized "已查询 …"
// tool-trace line, with no raw chat.* key leaking. uiLanguage axis (acc fixed to CN — the tool
// labels are regime-neutral). This locks the trace rendering + the per-tool i18n labels.
test.describe('ai assistant tool trace (R2b-1)', () => {
  for (const ui of UI_LANGUAGES) {
    test(`agent-trace ui=${ui}`, async ({ page }) => {
      await bootCombo(page, ui, 'CN');
      const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

      await page.route('**/api/ai/agent-chat', (route) => route.fulfill({
        json: {
          text: 'Annual sales total is 123,456.',
          toolTrace: [
            { name: 'get_sales', argsSummary: '', rowCount: 3, truncated: false },
            { name: 'get_dashboard', argsSummary: '{"year":"2026"}', rowCount: 0, truncated: false },
          ],
        },
      }));

      await page.locator('nav i.fa-comments').first().click();

      // send a message → triggers aiContext (catch-all {}) then the mocked agent-chat.
      // Submit via Enter (form onSubmit) rather than clicking the send button — the floating
      // widget's circular toggle (fixed bottom-right, z-10000) overlaps the send button corner.
      const input = page.getByPlaceholder(loc.chat.placeholder).first();
      await input.fill('今年销售总额多少？');
      await input.press('Enter');

      // (1) final answer renders
      await expect(page.getByText('Annual sales total is 123,456.').first()).toBeVisible({ timeout: 10_000 });
      // (2) tool-trace line: localized title + joined tool labels (joined string is unique to the trace,
      //     so it won't collide with the sidebar nav labels e.g. en "Sales")
      await expect(page.getByText(loc.chat.toolTraceTitle, { exact: false }).first()).toBeVisible({ timeout: 10_000 });
      const joined = [loc.chat.toolLabel.get_sales, loc.chat.toolLabel.get_dashboard].join(' · ');
      await expect(page.getByText(joined, { exact: false }).first()).toBeVisible({ timeout: 10_000 });
      // (3) no raw chat.* key leaked into the rendered UI
      const body = await page.locator('body').innerText();
      expect(body, `[ui=${ui}] raw chat key leaked`).not.toMatch(/chat\.[a-zA-Z]/);
    });
  }
});

// ── AI assistant conversation persistence (R4a-1) — mocked conversation endpoints ──
// Sending a message must lazily create a conversation (POST /api/conversations) then append
// BOTH the user message and the model reply (POST /api/conversations/:id/messages). The mock
// records those calls; we assert the conversation toolbar renders (new chat / clear) and that
// create + the two appends fired with the right role/text. Persistence degrades gracefully on
// failure (try/catch), so this only locks the happy path. Restore-on-reload is verified manually.
test.describe('ai assistant conversation persistence (R4a-1)', () => {
  test('conversation-persist ui=zh-CN → lazy create + append user/model', async ({ page }) => {
    const ui = 'zh-CN';
    await bootCombo(page, ui, 'CN');
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

    const calls: { kind: string; body: any }[] = [];
    // create / list (bare /api/conversations); registered after bootCombo → takes precedence
    await page.route('**/api/conversations', (route) => {
      const req = route.request();
      if (req.method() === 'POST') {
        calls.push({ kind: 'create', body: req.postDataJSON() });
        return route.fulfill({ json: { id: 'conv-e2e-1' } });
      }
      return route.fulfill({ json: [] });
    });
    // append / fetch messages (/api/conversations/:id/messages)
    await page.route('**/api/conversations/*/messages', (route) => {
      const req = route.request();
      if (req.method() === 'POST') {
        calls.push({ kind: 'append', body: req.postDataJSON() });
        return route.fulfill({ json: { ok: true } });
      }
      return route.fulfill({ json: [] });
    });
    await page.route('**/api/ai/agent-chat', (route) => route.fulfill({ json: { text: 'Persisted answer 42.' } }));

    await page.locator('nav i.fa-comments').first().click();

    // (1) conversation toolbar renders (resolved i18n, no raw key)
    await expect(page.getByText(loc.chat.newConversation).first()).toBeVisible({ timeout: 10_000 });

    // (2) send a message via Enter (the widget toggle overlaps the send button corner)
    const input = page.getByPlaceholder(loc.chat.placeholder).first();
    await input.fill('保存这条消息');
    await input.press('Enter');
    await expect(page.getByText('Persisted answer 42.').first()).toBeVisible({ timeout: 10_000 });

    // (3) lazy-created exactly one conversation, then appended user + model
    expect(calls.filter(c => c.kind === 'create').length).toBeGreaterThanOrEqual(1);
    const appends = calls.filter(c => c.kind === 'append');
    expect(appends.length).toBeGreaterThanOrEqual(2);
    expect(appends.some(a => a.body?.role === 'user' && a.body?.text === '保存这条消息')).toBeTruthy();
    expect(appends.some(a => a.body?.role === 'model' && a.body?.text === 'Persisted answer 42.')).toBeTruthy();

    // (4) no raw chat.* key leaked
    const body = await page.locator('body').innerText();
    expect(body, 'raw chat key leaked').not.toMatch(/chat\.[a-zA-Z]/);
  });
});

// ── AI assistant conversation history sidebar (R4a-2) — mocked conversation endpoints ──
// The AssistantPage sidebar lists conversations (refreshed after a send), switches on click
// (loads that conversation's messages), renames inline (PUT /api/conversations/:id), and deletes
// with a two-click confirm (DELETE /api/conversations/:id). We seed the list/messages and record
// the rename/delete calls. The floating widget has no sidebar (page-only).
test.describe('ai assistant conversation history (R4a-2)', () => {
  test('conversation-sidebar ui=zh-CN → list + switch + rename + delete', async ({ page }) => {
    const ui = 'zh-CN';
    await bootCombo(page, ui, 'CN');
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

    const calls: { kind: string; url: string; body: any }[] = [];
    await page.route('**/api/conversations', (route) => {
      const req = route.request();
      if (req.method() === 'POST') return route.fulfill({ json: { id: 'conv-new' } });
      // GET list → one prior conversation
      return route.fulfill({ json: [{ id: 'conv-prev', title: '历史对话', updated_at: '2026-06-10 09:00:00' }] });
    });
    await page.route('**/api/conversations/*/messages', (route) => {
      const req = route.request();
      if (req.method() === 'POST') return route.fulfill({ json: { ok: true } });
      // GET messages for the prior conversation
      return route.fulfill({ json: [{ role: 'user', text: '历史问题' }, { role: 'model', text: '历史回答' }] });
    });
    await page.route('**/api/conversations/*', (route) => {
      const req = route.request();
      if (req.method() === 'PUT') { calls.push({ kind: 'rename', url: req.url(), body: req.postDataJSON() }); return route.fulfill({ json: { ok: true } }); }
      if (req.method() === 'DELETE') { calls.push({ kind: 'delete', url: req.url(), body: null }); return route.fulfill({ json: { ok: true } }); }
      return route.fulfill({ json: {} });
    });
    await page.route('**/api/ai/agent-chat', (route) => route.fulfill({ json: { text: 'ok.' } }));

    await page.locator('nav i.fa-comments').first().click();
    await expect(page.getByText(loc.chat.historyTitle).first()).toBeVisible({ timeout: 10_000 });

    // (1) send a message → refreshConversations → the seeded prior conversation appears in the sidebar
    const input = page.getByPlaceholder(loc.chat.placeholder).first();
    await input.fill('触发刷新');
    await input.press('Enter');
    await expect(page.getByText('历史对话').first()).toBeVisible({ timeout: 10_000 });

    // (2) switch → clicking the history item loads its messages
    await page.getByText('历史对话').first().click();
    await expect(page.getByText('历史回答').first()).toBeVisible({ timeout: 10_000 });

    // (3) inline rename → PUT /api/conversations/conv-prev with the new title
    await page.getByTitle(loc.chat.renameConversation).first().click();
    const renameInput = page.getByPlaceholder(loc.chat.renamePlaceholder).first();
    await renameInput.fill('改名了');
    await renameInput.press('Enter');
    await expect.poll(() => calls.filter(c => c.kind === 'rename').length, { timeout: 10_000 }).toBeGreaterThanOrEqual(1);
    expect(calls.find(c => c.kind === 'rename')?.url).toContain('conv-prev');
    expect(calls.find(c => c.kind === 'rename')?.body?.title).toBe('改名了');

    // (4) two-click delete → DELETE /api/conversations/conv-prev
    await page.getByTitle(loc.chat.deleteConversation).first().click();
    await page.getByText(loc.chat.deleteConfirm).first().click();
    await expect.poll(() => calls.filter(c => c.kind === 'delete').length, { timeout: 10_000 }).toBeGreaterThanOrEqual(1);
    expect(calls.find(c => c.kind === 'delete')?.url).toContain('conv-prev');

    // (5) no raw chat.* key leaked
    const body = await page.locator('body').innerText();
    expect(body, 'raw chat key leaked').not.toMatch(/chat\.[a-zA-Z]/);
  });
});

// ── Business Documents create modal with a mocked desktop electronAPI (Phase A) ──
// The modal is uiLanguage-only (regime tax labels render via getTaxLabel with the
// frozen acc_locale and are covered by the matrix sweep), so one accountingLocale ×
// 6 UI langs is the meaningful axis (purchase-picker precedent). The mock keeps a
// stateful docs array so the happy-path create test can see its row after reload.
async function injectDocsElectronAPI(page: import('@playwright/test').Page, acc: string = 'CN', seedDocs: any[] = [], seedSales: any[] = []) {
  await page.addInitScript(({ settings, dashboard, seed, sales }) => {
    const lists = /\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|reports\/types)/;
    const docs: any[] = Array.isArray(seed) ? [...seed] : [];
    const salesRows: any[] = Array.isArray(sales) ? sales : [];
    (window as any).electronAPI = {
      isElectron: true,
      platform: 'darwin',
      buildTarget: 'dmg',
      invoke: (channel: string, payload: any) => {
        if (channel === 'providers:hasAny') return Promise.resolve(true);
        if (channel === 'providers:list') return Promise.resolve([]);
        // Phase B: the generic printToPDF IPC — capture the produced HTML for
        // content assertions and echo a deterministic saved path
        if (channel === 'app:exportReportPdf') {
          (window as any).__lastPdfHtml = (payload && payload.html) || '';
          const name = (payload && payload.defaultFileName) || 'SoloLedger-doc.pdf';
          return Promise.resolve({ ok: true, path: `/Users/test/Documents/${name}` });
        }
        // Phase D: attachment channels — pick returns a deterministic copied path,
        // open records what was requested, discard always succeeds
        if (channel === 'app:pickDocAttachment') {
          (window as any).__pickedDocId = payload && payload.docId;
          return Promise.resolve({ ok: true, relPath: 'attachments/docs/doc-tax-1-abc.pdf', fileName: 'fapiao.pdf' });
        }
        if (channel === 'app:openDocAttachment') {
          (window as any).__openedAttachment = payload && payload.relPath;
          return Promise.resolve({ ok: true });
        }
        if (channel === 'app:discardDocAttachment') return Promise.resolve({ ok: true });
        if (channel === 'api:request') {
          const method = (payload && payload.method) || 'GET';
          const p = (payload && payload.path) || '';
          // next-number must be matched BEFORE the generic documents list
          if (p.startsWith('/api/documents/next-number')) return Promise.resolve({ number: 'QT-2026-0001' });
          if (p.startsWith('/api/documents')) {
            if (method === 'POST') {
              const b = (payload && payload.body) || {};
              const items = Array.isArray(b.items) ? b.items : [];
              const subtotal = items.reduce((s: number, it: any) => s + (it.amount || 0), 0);
              const tax = items.reduce((s: number, it: any) => s + (it.tax_amount || 0), 0);
              docs.push({
                id: 'doc-e2e-1', doc_type: b.doc_type, doc_number: b.doc_number, status: 'draft',
                doc_date: b.doc_date, customer_name: b.customer_name, acc_locale: b.acc_locale || 'CN',
                subtotal, tax_amount: tax, total: subtotal + tax,
                source_sales_id: b.source_sales_id || null,
                period_start: b.period_start || null, period_end: b.period_end || null,
                items: b.items || [],
              });
              return Promise.resolve({ success: true, id: 'doc-e2e-1' });
            }
            // Phase D: PUT /:id/tax-invoice merges the snake_case fields into the seeded doc
            const tmm = /^\/api\/documents\/([^/?]+)\/tax-invoice$/.exec(p);
            if (tmm && method === 'PUT') {
              const d = docs.find((x: any) => x.id === tmm[1]);
              if (d) Object.assign(d, (payload && payload.body) || {});
              return Promise.resolve({ success: true });
            }
            // GET /api/documents/:id → single doc with items (the PDF export path)
            const m = /^\/api\/documents\/([^/?]+)$/.exec(p);
            if (m) {
              const found = docs.find((d: any) => d.id === m[1]);
              return Promise.resolve(found ? { ...found, items: found.items || [] } : {});
            }
            return Promise.resolve(docs);
          }
          // seeded sales rows (Phase C from-sales / statement tests) — must be
          // matched BEFORE the generic lists regex (it also contains "sales")
          if (p.startsWith('/api/sales') && method === 'GET') return Promise.resolve(salesRows);
          if (p.includes('/api/settings')) return Promise.resolve(settings);
          if (p.includes('/api/dashboard')) return Promise.resolve(dashboard);
          if (lists.test(p)) return Promise.resolve([]);
          return Promise.resolve({});
        }
        return Promise.resolve({});
      },
    };
  }, { settings: SETTINGS(acc), dashboard: DASHBOARD(acc), seed: seedDocs, sales: seedSales });
}

test.describe('business documents → create modal (desktop mock)', () => {
  for (const ui of UI_LANGUAGES) {
    test(`documents-modal ui=${ui}`, async ({ page }) => {
      const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
      await injectDocsElectronAPI(page);
      await bootCombo(page, ui, 'CN');
      await page.locator('nav i.fa-file-contract').first().click();

      // desktop mode → no desktop-only banner; the new-document button opens the modal
      await expect(page.getByText(loc.documents.desktopOnly)).toHaveCount(0);
      await page.locator('button:has(i.fa-plus)').first().click();

      // modal title + the 5 localized doc-type options + suggested internal number prefilled
      await expect(page.getByText(loc.documents.formTitle).first()).toBeVisible({ timeout: 10_000 });
      for (const k of ['typeQuotation', 'typeSalesOrder', 'typeProforma', 'typeCommercial', 'typeStatement']) {
        expect(await page.locator('option').filter({ hasText: loc.documents[k] }).count(), `[ui=${ui}] option ${k}`).toBeGreaterThan(0);
      }
      await expect(page.locator('input[name="docNumber"]')).toHaveValue('QT-2026-0001', { timeout: 10_000 });

      // no raw documents.* key leaked
      const body = await page.locator('body').innerText();
      expect(body, `[ui=${ui}] raw documents key leaked`).not.toMatch(/documents\.[a-zA-Z]/);
    });
  }

  // Happy path: fill the form → save → the new row (number + customer) appears in the list.
  test('documents-create → mock electronAPI happy path', async ({ page }) => {
    const ui = 'zh-CN';
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await injectDocsElectronAPI(page);
    await bootCombo(page, ui, 'CN');
    await page.locator('nav i.fa-file-contract').first().click();
    await page.locator('button:has(i.fa-plus)').first().click();
    await expect(page.locator('input[name="docNumber"]')).toHaveValue('QT-2026-0001', { timeout: 10_000 });

    await page.locator('input[name="customerName"]').fill('集成测试客户');
    await page.locator('input[name="itemDescription-0"]').fill('咨询服务');
    await page.locator('input[name="itemQty-0"]').fill('2');
    await page.locator('input[name="itemUnitPrice-0"]').fill('100');
    await page.getByRole('button', { name: loc.documents.saveButton }).click();

    // modal closes, the reloaded list shows the created document
    await expect(page.getByText(loc.documents.formTitle)).toHaveCount(0, { timeout: 10_000 });
    await expect(page.getByText('QT-2026-0001')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText('集成测试客户')).toBeVisible();
  });

  // Frozen-locale invariant: a saved document renders money with its OWN frozen
  // acc_locale even when the live setting differs (settings=JP, the seeded doc is
  // US → $); and the create modal under a non-CN regime resolves its tax labels
  // via getTaxLabel (a regression there returns the bare key — locked here).
  test('documents-frozen-locale ui=ja acc=JP', async ({ page }) => {
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', 'ja.json'), 'utf8'));
    await injectDocsElectronAPI(page, 'JP', [{
      id: 'doc-us-1', doc_type: 'quotation', doc_number: 'QT-2026-0042', status: 'draft',
      doc_date: '2026-06-01', customer_name: 'Frozen Co', acc_locale: 'US',
      subtotal: 100, tax_amount: 7, total: 107,
    }]);
    await bootCombo(page, 'ja', 'JP');
    await page.locator('nav i.fa-file-contract').first().click();

    // the US-frozen document keeps the $ symbol (not the live JP regime's ¥)
    await expect(page.getByText('$107.00')).toBeVisible({ timeout: 10_000 });

    // create modal under the live JP regime: regime labels must resolve (no bare keys)
    await page.locator('button:has(i.fa-plus)').first().click();
    await expect(page.getByText(loc.documents.formTitle).first()).toBeVisible({ timeout: 10_000 });
    const body = await page.locator('body').innerText();
    expect(body, 'bare getTaxLabel key leaked into the documents modal').not.toMatch(/\b(headerTaxAmount|headerTotalWithTax|formTaxRate)\b/);
  });

  // Phase B: per-row PDF export goes through the generic app:exportReportPdf IPC
  // (mock echoes the suggested filename back as the saved path). The flow exercises
  // GET /api/documents/:id (items load) → buildDocumentHtml → IPC → success banner.
  test('documents-export-pdf → mock electronAPI shows saved path', async ({ page }) => {
    const ui = 'zh-CN';
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await injectDocsElectronAPI(page, 'CN', [{
      id: 'doc-pdf-1', doc_type: 'quotation', doc_number: 'QT-2026-0042', status: 'draft',
      doc_date: '2026-06-01', customer_name: 'PDF 测试客户', acc_locale: 'CN',
      subtotal: 100, tax_amount: 13, total: 113,
      items: [{ id: 1, description: '咨询服务', quantity: 2, unit: 'session', unit_price: 50, tax_rate: '13%', tax_amount: 13, amount: 100, line_no: 0 }],
    }]);
    await bootCombo(page, ui, 'CN');
    await page.locator('nav i.fa-file-contract').first().click();
    await expect(page.getByText('QT-2026-0042')).toBeVisible({ timeout: 10_000 });

    await page.getByRole('button', { name: loc.documents.exportPdf }).click();
    await expect(page.getByText(/SoloLedger-QT-2026-0042\.pdf/)).toBeVisible({ timeout: 10_000 });

    // the produced HTML carries the Phase B contract: doc number, line item,
    // frozen-locale money and the unconditional non-tax-invoice disclaimer
    const html = await page.evaluate(() => (window as any).__lastPdfHtml as string);
    expect(html).toContain('QT-2026-0042');
    expect(html).toContain('咨询服务');
    expect(html).toContain('¥113.00');
    expect(html).toContain(loc.documents.pdfDisclaimer);
  });
});

// ── Phase C: 销售页 → 生成单据 (shared DocumentModal prefill) + 对账单生成器 ──
// The seeded sales row deliberately has amountWithoutTax (884.96) ≠ tons×pricePerTon
// (3×294.99=884.97): the modal must show the COPIED stored amount, proving the
// locked-row no-recompute contract. Navigation: sidebar fa-file-export → sales page.
const SALES_SEED = {
  id: 'sale-c-1', date: '2026-06-03', customer: '单据测试客户', tons: 3, pricePerTon: 294.99,
  totalAmount: 1000, amountWithoutTax: 884.96, taxAmount: 115.04, taxRate: 13, shippingCost: 0,
  invoiceNumber: 'INV-001', invoiceStatus: '已开', product_id: 'p1', product_name_snapshot: '货物A', unit_snapshot: 'ton',
};

test.describe('business documents → generate from sales (Phase C)', () => {
  for (const ui of UI_LANGUAGES) {
    test(`from-sales modal ui=${ui}`, async ({ page }) => {
      const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
      await injectDocsElectronAPI(page, 'CN', [], [SALES_SEED]);
      await bootCombo(page, ui, 'CN');
      await page.locator('nav i.fa-file-export').first().click();

      // the seeded row renders, the per-row generate button opens the shared modal
      await expect(page.getByText('单据测试客户').first()).toBeVisible({ timeout: 10_000 });
      await page.getByRole('button', { name: loc.documents.generateFromSale }).click();

      // create modal opens prefilled: customer name + suggested internal number
      await expect(page.getByText(loc.documents.formTitle).first()).toBeVisible({ timeout: 10_000 });
      await expect(page.locator('input[name="customerName"]')).toHaveValue('单据测试客户');
      await expect(page.locator('input[name="docNumber"]')).toHaveValue('QT-2026-0001', { timeout: 10_000 });

      // switch to statement: the generator panel renders its localized labels
      // (covers the stmt* keys in all 6 languages, not just the zh-CN flow test)
      await page.locator('select[name="docType"]').selectOption('statement');
      await expect(page.getByRole('button', { name: loc.documents.stmtGenerate })).toBeVisible({ timeout: 10_000 });
      await expect(page.locator('select[name="stmtCustomer"]')).toBeVisible();

      const body = await page.locator('body').innerText();
      expect(body, `[ui=${ui}] raw documents key leaked`).not.toMatch(/documents\.[a-zA-Z]/);
    });
  }

  // Happy path incl. the copy-not-recompute lock: the line shows the stored
  // ¥884.96 (recompute would give ¥884.97) → save → row appears on the documents page.
  test('from-sales → mock electronAPI happy path (copied amounts)', async ({ page }) => {
    const ui = 'zh-CN';
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await injectDocsElectronAPI(page, 'CN', [], [SALES_SEED]);
    await bootCombo(page, ui, 'CN');
    await page.locator('nav i.fa-file-export').first().click();
    await expect(page.getByText('单据测试客户').first()).toBeVisible({ timeout: 10_000 });
    await page.getByRole('button', { name: loc.documents.generateFromSale }).click();
    await expect(page.locator('input[name="docNumber"]')).toHaveValue('QT-2026-0001', { timeout: 10_000 });

    // locked amounts copied from the sales record — NOT recomputed from qty×price.
    // Scope to the modal <form> (the sales table BEHIND the modal shows the same
    // strings, which would make an unscoped assertion vacuous), and assert the
    // recomputed value (3 × 294.99 = 884.97) appears nowhere.
    const modalForm = page.locator('form');
    await expect(modalForm.getByText('¥884.96').first()).toBeVisible();
    await expect(modalForm.getByText('¥1,000.00').first()).toBeVisible();
    await expect(page.getByText('¥884.97')).toHaveCount(0);

    await page.getByRole('button', { name: loc.documents.saveButton }).click();
    await expect(page.getByText(loc.documents.formTitle)).toHaveCount(0, { timeout: 10_000 });
    await expect(page.getByText(loc.documents.generatedOk)).toBeVisible({ timeout: 10_000 });

    // the created document is visible on the documents page with the copied total
    await page.locator('nav i.fa-file-contract').first().click();
    await expect(page.getByText('QT-2026-0001')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText('¥1,000.00').first()).toBeVisible();
  });

  // Statement generator: trim-exact customer matching ('对账客户 ' with a trailing
  // space and '对账客户' are the same customer) + period filter + summed locked totals.
  test('statement generator → trim match + period + copied totals', async ({ page }) => {
    const ui = 'zh-CN';
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    // sale-s-1 is deliberately recompute-sensitive: 3 × 33.33 = 99.99 ≠ stored 100.00,
    // so a locked-row regression shifts the totals to ¥338.99 and fails the ¥339.00 asserts
    await injectDocsElectronAPI(page, 'CN', [], [
      { id: 'sale-s-1', date: '2026-06-01', customer: '对账客户', tons: 3, pricePerTon: 33.33, totalAmount: 113, amountWithoutTax: 100, taxAmount: 13, taxRate: 13, shippingCost: 0, invoiceNumber: '', invoiceStatus: '已开', product_id: 'p1', product_name_snapshot: '货物A', unit_snapshot: 'ton' },
      { id: 'sale-s-2', date: '2026-06-05', customer: '对账客户 ', tons: 2, pricePerTon: 100, totalAmount: 226, amountWithoutTax: 200, taxAmount: 26, taxRate: 13, shippingCost: 0, invoiceNumber: 'INV-9', invoiceStatus: '已开', product_id: null, product_name_snapshot: null, unit_snapshot: null },
      { id: 'sale-s-3', date: '2026-07-01', customer: '对账客户', tons: 1, pricePerTon: 100, totalAmount: 113, amountWithoutTax: 100, taxAmount: 13, taxRate: 13, shippingCost: 0, invoiceNumber: '', invoiceStatus: '已开', product_id: 'p1', product_name_snapshot: '货物A', unit_snapshot: 'ton' },
    ]);
    await bootCombo(page, ui, 'CN');
    await page.locator('nav i.fa-file-contract').first().click();
    await page.locator('button:has(i.fa-plus)').first().click();
    await expect(page.locator('input[name="docNumber"]')).toHaveValue('QT-2026-0001', { timeout: 10_000 });

    // switch to statement → generator appears; the two trim-variants collapse to ONE option
    await page.locator('select[name="docType"]').selectOption('statement');
    await expect(page.locator('select[name="stmtCustomer"]')).toBeVisible({ timeout: 10_000 });
    expect(await page.locator('select[name="stmtCustomer"] option').filter({ hasText: '对账客户' }).count()).toBe(1);

    await page.locator('select[name="stmtCustomer"]').selectOption('对账客户');
    await page.locator('input[name="stmtStart"]').fill('2026-06-01');
    await page.locator('input[name="stmtEnd"]').fill('2026-06-30');
    await page.getByRole('button', { name: loc.documents.stmtGenerate }).click();

    // both June rows (trim-matched) are generated; the July row is excluded
    await expect(page.locator('input[name="itemDescription-0"]')).toHaveValue('2026-06-01 货物A');
    await expect(page.locator('input[name="itemDescription-1"]')).toHaveValue('2026-06-05 INV-9');
    await expect(page.locator('input[name="customerName"]')).toHaveValue('对账客户');
    // totals = COPIED sums: 300 subtotal + 39 tax = 339 (a recompute would show ¥338.99)
    await expect(page.locator('form').getByText('¥339.00').first()).toBeVisible();
    await expect(page.getByText('¥338.99')).toHaveCount(0);

    await page.getByRole('button', { name: loc.documents.saveButton }).click();
    await expect(page.getByText(loc.documents.formTitle)).toHaveCount(0, { timeout: 10_000 });
    await expect(page.getByText('对账客户').first()).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText('¥339.00').first()).toBeVisible();
    // the statement's defining attribute — its period — is surfaced in the list
    await expect(page.getByText('2026-06-01 ~ 2026-06-30')).toBeVisible();
  });
});

// ── Phase D: 正式税务发票关联 (records an EXTERNALLY issued invoice — never issues) ──
// The linkage modal is uiLanguage-only; one accountingLocale × 6 UI langs covers the
// label axis (purchase-picker precedent). The happy path exercises the dedicated
// PUT /:id/tax-invoice sub-route + the attachment pick/open mock channels.
const TAX_DOC_SEED = {
  id: 'doc-tax-1', doc_type: 'commercial_invoice', doc_number: 'CI-2026-0007', status: 'issued',
  doc_date: '2026-06-10', customer_name: '发票关联客户', acc_locale: 'CN',
  subtotal: 100, tax_amount: 13, total: 113,
  tax_invoice_issued: 0, tax_invoice_number: null, tax_invoice_date: null, tax_invoice_attachment_path: null,
};

test.describe('business documents → tax invoice link (Phase D)', () => {
  for (const ui of UI_LANGUAGES) {
    test(`tax-invoice modal ui=${ui}`, async ({ page }) => {
      const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
      await injectDocsElectronAPI(page, 'CN', [{ ...TAX_DOC_SEED }]);
      await bootCombo(page, ui, 'CN');
      await page.locator('nav i.fa-file-contract').first().click();

      await expect(page.getByText('CI-2026-0007')).toBeVisible({ timeout: 10_000 });
      await page.getByRole('button', { name: loc.documents.taxInvoiceAction }).click();

      // modal renders: title, issued checkbox label, manual-only hint,
      // compliance banner (records only / never issues), backup-limitation hint
      await expect(page.getByText(loc.documents.taxInvoiceTitle).first()).toBeVisible({ timeout: 10_000 });
      await expect(page.getByText(loc.documents.taxInvoiceIssuedLabel)).toBeVisible();
      await expect(page.getByText(loc.documents.taxInvoiceNumberHint)).toBeVisible();
      await expect(page.getByText(loc.documents.taxInvoiceCompliance)).toBeVisible();
      await expect(page.getByText(loc.documents.attachmentNotBackedUp)).toBeVisible();

      const body = await page.locator('body').innerText();
      expect(body, `[ui=${ui}] raw documents key leaked`).not.toMatch(/documents\.[a-zA-Z]/);
    });
  }

  // Happy path: mark issued + manual number + date + pick attachment → save via the
  // dedicated sub-route → list shows the issued badge + paperclip; reopen → Open
  // goes through the containment-checked IPC with the stored relative path.
  test('tax-invoice → mock electronAPI happy path', async ({ page }) => {
    const ui = 'zh-CN';
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await injectDocsElectronAPI(page, 'CN', [{ ...TAX_DOC_SEED }]);
    await bootCombo(page, ui, 'CN');
    await page.locator('nav i.fa-file-contract').first().click();
    await expect(page.getByText('CI-2026-0007')).toBeVisible({ timeout: 10_000 });
    await page.getByRole('button', { name: loc.documents.taxInvoiceAction }).click();
    await expect(page.getByText(loc.documents.taxInvoiceTitle).first()).toBeVisible({ timeout: 10_000 });

    await page.locator('input[name="taxInvoiceIssued"]').check();
    await page.locator('input[name="taxInvoiceNumber"]').fill('INV-EXT-001');
    await page.locator('input[name="taxInvoiceDate"]').fill('2026-06-11');
    await page.getByRole('button', { name: loc.documents.attachmentPick }).click();
    await expect(page.getByText('fapiao.pdf')).toBeVisible({ timeout: 10_000 });
    // the pick IPC received the document id (filenames embed it)
    expect(await page.evaluate(() => (window as any).__pickedDocId)).toBe('doc-tax-1');

    await page.getByRole('button', { name: loc.documents.saveButton }).click();
    await expect(page.getByText(loc.documents.taxInvoiceTitle)).toHaveCount(0, { timeout: 10_000 });

    // list reflects the merged tax fields: issued badge + paperclip icon
    await expect(page.getByText(loc.documents.taxInvoiceYes)).toBeVisible({ timeout: 10_000 });
    await expect(page.locator('td i.fa-paperclip')).toBeVisible();

    // reopen → the persisted values render (saved attachment shows its stored copy
    // name); Open passes the stored relative path through the containment-checked IPC
    await page.getByRole('button', { name: loc.documents.taxInvoiceAction }).click();
    await expect(page.locator('input[name="taxInvoiceNumber"]')).toHaveValue('INV-EXT-001', { timeout: 10_000 });
    await expect(page.getByText('doc-tax-1-abc.pdf')).toBeVisible();
    await page.getByRole('button', { name: loc.documents.attachmentOpen }).click();
    expect(await page.evaluate(() => (window as any).__openedAttachment)).toBe('attachments/docs/doc-tax-1-abc.pdf');
  });

  // Void documents: linkage info is READ-ONLY (terminal state); Open still available.
  test('tax-invoice → void document is read-only', async ({ page }) => {
    const ui = 'zh-CN';
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await injectDocsElectronAPI(page, 'CN', [{
      ...TAX_DOC_SEED, id: 'doc-tax-void', doc_number: 'CI-2026-0008', status: 'void',
      tax_invoice_issued: 1, tax_invoice_number: 'INV-EXT-009', tax_invoice_date: '2026-06-01',
      tax_invoice_attachment_path: 'attachments/docs/doc-tax-void-old.pdf',
    }]);
    await bootCombo(page, ui, 'CN');
    await page.locator('nav i.fa-file-contract').first().click();
    await expect(page.getByText('CI-2026-0008')).toBeVisible({ timeout: 10_000 });
    await page.getByRole('button', { name: loc.documents.taxInvoiceAction }).click();

    await expect(page.getByText(loc.documents.taxInvoiceVoidReadOnly)).toBeVisible({ timeout: 10_000 });
    await expect(page.locator('input[name="taxInvoiceNumber"]')).toBeDisabled();
    await expect(page.locator('input[name="taxInvoiceIssued"]')).toBeDisabled();
    await expect(page.locator('input[name="taxInvoiceDate"]')).toBeDisabled();
    // no save/remove in read-only mode; Open is still offered for the attachment
    await expect(page.getByRole('button', { name: loc.documents.saveButton })).toHaveCount(0);
    await expect(page.getByRole('button', { name: loc.documents.attachmentRemove })).toHaveCount(0);
    await expect(page.getByRole('button', { name: loc.documents.attachmentOpen })).toBeVisible();
  });
});

test.afterAll(async () => {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
  const summary = {
    total: UI_LANGUAGES.length * ACCOUNTING_LOCALES.length,
    failed: failures.length,
    failures,
  };
  fs.writeFileSync(path.join(SCREENSHOT_DIR, 'summary.json'), JSON.stringify(summary, null, 2));
  console.log(`\n[locale-ui] ${summary.total - failures.length}/${summary.total} combinations passed. Screenshots + summary.json in ${SCREENSHOT_DIR}/`);
});
