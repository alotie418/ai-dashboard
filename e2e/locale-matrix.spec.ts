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
