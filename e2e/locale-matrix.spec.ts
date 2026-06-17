import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { SETTINGS, DASHBOARD } from './helpers/fixtures';
import { bootComboIPC, gotoApp } from './helpers/electronMock';

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

// SETTINGS / DASHBOARD now live in ./helpers/fixtures (shared by the Web-boot
// bootCombo path and the IPC-boot installElectronMock path) — see Phase 3 doc.

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
      // ── IPC-boot: inject mock electronAPI so the SPA boots through the desktop
      //    IPC path and resolves this accountingLocale (Phase 3 PR-3.1) ──
      await bootComboIPC(page, ui, acc);
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
// Phase 3 PR-3.7: the legacy Web-boot bootCombo() helper was removed — every test now
// boots through the IPC mock (bootComboIPC / installElectronMock + gotoApp).
test.describe('settings → products/services tab', () => {
  for (const acc of ACCOUNTING_LOCALES) {
    for (const ui of UI_LANGUAGES) {
      test(`products-tab ui=${ui} acc=${acc}`, async ({ page }) => {
        await bootComboIPC(page, ui, acc); // Phase 3 PR-3.2

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
      await bootComboIPC(page, ui, acc); // Phase 3 PR-3.2 (acc='CN')
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
// uiLanguage-only feature. Navigation uses stable icons (sidebar fa-cog → settings;
// sub-tab fa-box-archive → data backup).
// Phase 3 PR-3.7: IPC-only boot. The desktop build always HAS electronAPI, so this
// now verifies the real desktop UI: the section renders its title + enabled
// backup / restore action buttons and does NOT show the desktop-only notice — the
// no-electronAPI degradation is no longer the contract under test.
test.describe('settings → data backup tab', () => {
  for (const acc of ACCOUNTING_LOCALES) {
    for (const ui of UI_LANGUAGES) {
      test(`data-backup-tab ui=${ui} acc=${acc}`, async ({ page }) => {
        await bootComboIPC(page, ui, acc);
        const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
        const db = loc.settings.dataBackup;

        await page.locator('i.fa-cog').first().click();
        await page.locator('button:has(i.fa-box-archive)').click();

        // (1) title heading renders the resolved translation (proves the key is not a raw leak)
        await expect(page.getByRole('heading', { name: db.title })).toBeVisible({ timeout: 10_000 });
        // (2) desktop mode → real backup/restore action buttons render, no desktop-only notice
        await expect(page.getByRole('button', { name: db.backupButton })).toBeVisible({ timeout: 10_000 });
        await expect(page.getByRole('button', { name: db.restoreButton })).toBeVisible();
        await expect(page.getByText(db.desktopOnly)).toHaveCount(0);
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

  await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI above
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

// ── OCR preview → "use these values" → add-form pre-filled (PR-3c; mocked desktop electronAPI) ──
// Mocks an OCR-capable provider (providers:list) + a canned /api/ai/ocr result, uploads an image,
// opens the read-only preview, clicks "use these values", and asserts the add-form inputs are
// pre-filled. NO save happens (no createPurchase/createSale) — this is the confirm→fill closed loop.
const TINY_PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const OCR_RAW = { isInvoiceLike: true, sellerName: 'OCR Test Vendor', netAmount: 1000, taxAmount: 130, grossAmount: 1130, invoiceNumber: 'INV-OCR-2026', quantity: '10', date: '2026-06-13', currency: 'CNY', invoiceType: 'vat' };
const ocrInit = ({ settings, dashboard, ocr }: any) => {
  const lists = /\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|mileage|documents|reports\/types)/;
  (window as any).electronAPI = {
    isElectron: true, platform: 'darwin', buildTarget: 'dmg',
    invoke: (channel: string, payload: any) => {
      if (channel === 'providers:hasAny') return Promise.resolve(true);
      if (channel === 'providers:list') return Promise.resolve([{ provider: 'qwen', name: 'Qwen', hasKey: true, model: 'qwen-plus', modelLabel: 'Qwen Plus', modelIsKnown: true, availableModels: [], defaultModel: 'qwen-plus', enabled: true, isDefault: true, supportsOCR: true, supportsWebGrounding: false }]);
      if (channel === 'api:request') {
        const p = (payload && payload.path) || '';
        if (p.includes('/api/ai/ocr')) return Promise.resolve(ocr);
        if (p.includes('/api/settings')) return Promise.resolve(settings);
        if (p.includes('/api/dashboard')) return Promise.resolve(dashboard);
        if (lists.test(p)) return Promise.resolve([]);
        return Promise.resolve({});
      }
      return Promise.resolve({});
    },
  };
};

for (const { navIcon, label } of [{ navIcon: 'fa-file-import', label: 'purchase' }, { navIcon: 'fa-file-export', label: 'sales' }]) {
  test(`OCR preview → confirm → ${label} form pre-filled (no save)`, async ({ page }) => {
    const ui = 'zh-CN';
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await page.addInitScript(ocrInit, { settings: SETTINGS('CN'), dashboard: DASHBOARD('CN'), ocr: OCR_RAW });
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
    await page.locator(`i.${navIcon}`).first().click();
    // upload an image to the hidden OCR file input (hidden inputs accept setInputFiles)
    await page.locator('input[type="file"][accept*="image"]').setInputFiles({ name: 'invoice.png', mimeType: 'image/png', buffer: Buffer.from(TINY_PNG_B64, 'base64') });
    // read-only preview appears
    await expect(page.getByText(loc.ocr.previewTitle)).toBeVisible({ timeout: 15_000 });
    // "use these values" → fills the add-form state and opens the add modal (no DB write)
    await page.getByRole('button', { name: loc.ocr.useResult }).click();
    // add-form pre-filled with the recognized values (counterparty text + total number)
    await expect(page.getByTestId('ocr-fill-counterparty')).toHaveValue('OCR Test Vendor', { timeout: 10_000 });
    await expect(page.getByTestId('ocr-fill-total')).toHaveValue('1130');
  });
}

// ── BYOK provider display name follows UI language (provider-name-i18n) ──
// Under a non-Chinese UI the domestic providers must show their English brand names with NO Chinese
// residue. Mocks an electronAPI with all 8 providers (providers:list), opens Settings → AI Providers,
// and asserts the English names render and the Chinese brand strings do not appear anywhere.
const PROVIDER_NAME_IDS = ['anthropic', 'openai', 'gemini', 'deepseek', 'qwen', 'kimi', 'glm', 'doubao'];
for (const ui of ['en', 'ja']) {
  test(`BYOK provider names follow UI language — ${ui} (no Chinese residue)`, async ({ page }) => {
    await page.addInitScript(({ settings, dashboard, ids }: any) => {
      const lists = /\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|mileage|documents|reports\/types)/;
      (window as any).electronAPI = {
        isElectron: true, platform: 'darwin', buildTarget: 'dmg',
        invoke: (channel: string, payload: any) => {
          if (channel === 'providers:hasAny') return Promise.resolve(true);
          if (channel === 'providers:list') return Promise.resolve(ids.map((id: string) => ({ provider: id, name: id, hasKey: false, model: '', modelLabel: '', modelIsKnown: false, availableModels: [], defaultModel: '', enabled: false, isDefault: false, supportsOCR: false, supportsWebGrounding: false })));
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
    }, { settings: SETTINGS('CN'), dashboard: DASHBOARD('CN'), ids: PROVIDER_NAME_IDS });
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
    await page.locator('i.fa-cog').first().click();        // → settings
    await page.locator('i.fa-microchip').first().click();   // → AI providers section
    // English brand names render (domestic providers de-sinicized under non-zh UI)
    await expect(page.getByText('Qwen · Alibaba Cloud')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText('Doubao · Volcano Engine')).toBeVisible();
    await expect(page.getByText('Kimi · Moonshot AI')).toBeVisible();
    // No Chinese provider-name residue anywhere in the panel
    const body = await page.locator('body').innerText();
    for (const cn of ['深度求索', '通义千问', '阿里云', '月之暗面', '智谱', '豆包', '火山方舟']) {
      expect(body, `${ui}: BYOK must not show "${cn}"`).not.toContain(cn);
    }
  });
}

// ── Finance → Export PDF button (uiLanguage-only feature). The finance page renders
//    a P&L from /api/reports/generate, so a valid report payload is mocked (empty {}
//    would crash it). Navigation via the sidebar fa-wallet icon. ──
const REPORT_MOCK = (acc: string) => ({
  locale: acc, period: { from: '2026-01-01', to: '2026-12-31', year: '2026' }, currency: '', reportTypes: [], warnings: [],
  incomeStatement: { salesRevenue: 100000, costOfSales: 60000, costOfGoodsSold: 60000, operatingExpenses: 0, grossProfit: 40000, adminExpense: 5000, operatingProfit: 35000, incomeTax: 6000, netProfit: 28000, netMargin: 28 },
  profitLoss: { revenue: 100000, costOfSales: 60000, costOfGoodsSold: 60000, operatingExpenses: 0, grossProfit: 40000, adminExpense: 5000, operatingProfit: 35000, incomeTax: 6000, netProfit: 28000, netMargin: 28 },
  scheduleC: { line1_grossReceipts: 100000, line7_grossIncome: 100000, line28_totalExpenses: 60000, line31_netProfit: 40000 },
});
// Phase 3 PR-3.7: the legacy Web-boot bootFinance() helper was removed; the finance
// tests boot through bootComboIPC with REPORT_MOCK supplied via apiResponses.

test.describe('finance → export PDF', () => {
  const FINANCE_COMBOS = [{ ui: 'zh-CN', acc: 'CN' }, { ui: 'en', acc: 'US' }, { ui: 'ja', acc: 'JP' }];
  for (const { ui, acc } of FINANCE_COMBOS) {
    // Phase 3 PR-3.7: IPC-only boot. The desktop build always HAS electronAPI, so
    // clicking export now goes through the app:exportReportPdf IPC and surfaces the
    // saved path (was: the no-electronAPI desktop-only notice). The finance page
    // also needs a valid /api/reports/generate payload (empty {} would crash it).
    test(`export-pdf button ui=${ui} acc=${acc}`, async ({ page }) => {
      await bootComboIPC(page, ui, acc, {
        apiResponses: [{ match: '/api/reports/generate', json: REPORT_MOCK(acc) }],
        appChannels: { 'app:exportReportPdf': { ok: true, path: '/Users/test/Reports/finance-export.pdf' } },
      });
      const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
      await page.locator('i.fa-wallet').first().click(); // → finance page
      const btn = page.locator('button:has(i.fa-file-pdf)');
      await expect(btn).toBeVisible({ timeout: 10_000 });
      // report tab labels must follow UI language (regression lock: ja/ko/fr Balance Sheet / Cash Flow)
      await expect(page.getByRole('button', { name: loc.finance.tabBalance })).toBeVisible();
      await expect(page.getByRole('button', { name: loc.finance.tabCashflow })).toBeVisible();
      // desktop mode → clicking exports via IPC and shows the saved path, no crash
      await btn.click();
      await expect(page.getByText(/finance-export\.pdf/)).toBeVisible({ timeout: 10_000 });
      // no raw finance.pdf* / finance.exportPdf key leaked
      const body = await page.locator('body').innerText();
      expect(body, `[ui=${ui} acc=${acc}] raw finance.pdf key`).not.toMatch(/finance\.pdf[A-Za-z]|finance\.exportPdf/);
    });
  }

  // PR-T1: Balance / Cash Flow render an honest "not enabled yet" empty state
  // (no zero-filled statement). Verify the coming-soon copy renders, not a $0 total.
  test('balance / cashflow show coming-soon empty state', async ({ page }) => {
    const ui = 'zh-CN';
    // Phase 3 PR-3.3: IPC-boot; the finance P&L tab needs /api/reports/generate.
    await bootComboIPC(page, ui, 'CN', { apiResponses: [{ match: '/api/reports/generate', json: REPORT_MOCK('CN') }] });
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await page.locator('i.fa-wallet').first().click(); // → finance page
    await page.getByRole('button', { name: loc.finance.tabBalance }).click();
    // heading role disambiguates from the tab button, whose label may share text
    await expect(page.getByRole('heading', { name: loc.finance.balanceComingSoonTitle })).toBeVisible({ timeout: 10_000 });
    await page.getByRole('button', { name: loc.finance.tabCashflow }).click();
    await expect(page.getByRole('heading', { name: loc.finance.cashflowTitle })).toBeVisible({ timeout: 10_000 });
  });

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
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI above
    await page.locator('i.fa-wallet').first().click();
    await page.locator('button:has(i.fa-file-pdf)').click();
    await expect(page.getByText(/SoloLedger-CN-pl-2026\.pdf/)).toBeVisible({ timeout: 10_000 });
  });
});

// ── Business Documents page renders across all 36 combos (Phase A) ──
// uiLanguage-only feature. Navigation uses the sidebar fa-file-contract icon, scoped
// to <nav> (NavItem is a <div>, not a <button>).
// Phase 3 PR-3.7: IPC-only boot. The desktop build always HAS electronAPI, so this
// now verifies the real desktop UI: the page renders its title, the empty-list state
// (GET /api/documents → []), and the enabled new-document button — and does NOT show
// the desktop-only notice. The create / from-sales / tax-invoice groups below exercise
// the deeper IPC flows via injectDocsElectronAPI.
test.describe('business documents page', () => {
  for (const acc of ACCOUNTING_LOCALES) {
    for (const ui of UI_LANGUAGES) {
      test(`documents-page ui=${ui} acc=${acc}`, async ({ page }) => {
        await bootComboIPC(page, ui, acc);
        const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

        await page.locator('nav i.fa-file-contract').first().click();

        // (1) title renders the resolved translation (proves the key is not a raw leak)
        await expect(page.getByRole('heading', { name: loc.documents.title }).first()).toBeVisible({ timeout: 10_000 });
        // (2) desktop mode → real UI: empty-list state + new-document button, no desktop-only notice
        await expect(page.getByText(loc.documents.empty)).toBeVisible({ timeout: 10_000 });
        await expect(page.locator('button:has(i.fa-plus)').first()).toBeVisible();
        await expect(page.getByText(loc.documents.desktopOnly)).toHaveCount(0);
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
        await bootComboIPC(page, ui, acc); // Phase 3 PR-3.4
        const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

        await page.locator('nav i.fa-comments').first().click();

        // (1) header title renders the resolved translation (proves the key is not a raw leak)
        await expect(page.getByRole('heading', { name: loc.headerTitle.assistant }).first()).toBeVisible({ timeout: 10_000 });
        // (2) the page's ChatPanel is mounted: empty-state welcome + input placeholder render
        await expect(page.getByText(loc.chat.welcome).first()).toBeVisible({ timeout: 10_000 });
        await expect(page.getByPlaceholder(loc.chat.placeholder).first()).toBeVisible({ timeout: 10_000 });
        // (PR-E1) the management-estimate disclaimer renders below the chat input
        await expect(page.getByText(loc.disclaimer.ai).first()).toBeVisible({ timeout: 10_000 });
        // (3) no raw chat.* / nav.assistant / headerTitle.assistant key leaked into the rendered UI
        const body = await page.locator('body').innerText();
        expect(body, `[ui=${ui} acc=${acc}] raw assistant key leaked`).not.toMatch(/chat\.[a-zA-Z]|nav\.assistant|headerTitle\.assistant/);
      });
    }
  }
});

// ── AI assistant read-only tool trace (R2b-1) — mocked agent-chat happy path ──
// The assistant page now sends through aiAgentChat (POST /api/ai/agent-chat). We mock that
// endpoint (via bootComboIPC apiResponses) to return a deterministic answer +
// a toolTrace, then assert the chat renders BOTH the final answer AND the localized "已查询 …"
// tool-trace line, with no raw chat.* key leaking. uiLanguage axis (acc fixed to CN — the tool
// labels are regime-neutral). This locks the trace rendering + the per-tool i18n labels.
test.describe('ai assistant tool trace (R2b-1)', () => {
  for (const ui of UI_LANGUAGES) {
    test(`agent-trace ui=${ui}`, async ({ page }) => {
      // Phase 3 PR-3.4: IPC-boot; the mocked agent-chat response is supplied via
      // apiResponses (matched before settings/dashboard/lists in api:request).
      await bootComboIPC(page, ui, 'CN', {
        apiResponses: [{
          match: '/api/ai/agent-chat',
          json: {
            text: 'Annual sales total is 123,456.',
            toolTrace: [
              { name: 'get_sales', argsSummary: '', rowCount: 3, truncated: false },
              { name: 'get_dashboard', argsSummary: '{"year":"2026"}', rowCount: 0, truncated: false },
            ],
          },
        }],
      });
      const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

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
// Phase 3 PR-3.7: IPC-boot. Conversation endpoints are answered via apiResponses;
// the lazy create + the user/model appends are recorded browser-side (window.__calls)
// and read back via page.evaluate (replacing the legacy Node-side page.route recording).
test.describe('ai assistant conversation persistence (R4a-1)', () => {
  test('conversation-persist ui=zh-CN → lazy create + append user/model', async ({ page }) => {
    const ui = 'zh-CN';
    await bootComboIPC(page, ui, 'CN', {
      recordCalls: true,
      apiResponses: [
        { match: '^/api/conversations/[^/]+/messages$', method: 'POST', json: { ok: true } },
        { match: '^/api/conversations/[^/]+/messages$', method: 'GET', json: [] },
        { match: '^/api/conversations$', method: 'POST', json: { id: 'conv-e2e-1' } },
        { match: '^/api/conversations$', method: 'GET', json: [] },
        { match: '/api/ai/agent-chat', json: { text: 'Persisted answer 42.' } },
      ],
    });
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

    await page.locator('nav i.fa-comments').first().click();

    // (1) conversation toolbar renders (resolved i18n, no raw key)
    await expect(page.getByText(loc.chat.newConversation).first()).toBeVisible({ timeout: 10_000 });

    // (2) send a message via Enter (the widget toggle overlaps the send button corner)
    const input = page.getByPlaceholder(loc.chat.placeholder).first();
    await input.fill('保存这条消息');
    await input.press('Enter');
    await expect(page.getByText('Persisted answer 42.').first()).toBeVisible({ timeout: 10_000 });

    // (3) lazy-created exactly one conversation, then appended user + model — read the
    //     browser-recorded IPC calls (the model append fires just after the reply renders,
    //     so poll until both appends land before snapshotting the bodies).
    const appendCount = async () => page.evaluate(() => ((window as any).__calls || [])
      .filter((c: any) => c.channel === 'api:request' && c.method === 'POST' && /^\/api\/conversations\/[^/]+\/messages$/.test(String(c.path || '').split('?')[0])).length);
    await expect.poll(appendCount, { timeout: 10_000 }).toBeGreaterThanOrEqual(2);

    const calls = await page.evaluate(() => (window as any).__calls || []);
    const clean = (c: any) => String(c.path || '').split('?')[0];
    const creates = calls.filter((c: any) => c.channel === 'api:request' && c.method === 'POST' && /^\/api\/conversations$/.test(clean(c)));
    const appends = calls.filter((c: any) => c.channel === 'api:request' && c.method === 'POST' && /^\/api\/conversations\/[^/]+\/messages$/.test(clean(c)));
    expect(creates.length).toBeGreaterThanOrEqual(1);
    expect(appends.length).toBeGreaterThanOrEqual(2);
    expect(appends.some((a: any) => a.body?.role === 'user' && a.body?.text === '保存这条消息')).toBeTruthy();
    expect(appends.some((a: any) => a.body?.role === 'model' && a.body?.text === 'Persisted answer 42.')).toBeTruthy();

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
    // Phase 3 PR-3.7: IPC-boot; seeded list/messages via apiResponses, rename/delete
    // recorded browser-side (window.__calls) and read back via page.evaluate.
    await bootComboIPC(page, ui, 'CN', {
      recordCalls: true,
      apiResponses: [
        { match: '^/api/conversations/[^/]+/messages$', method: 'POST', json: { ok: true } },
        { match: '^/api/conversations/[^/]+/messages$', method: 'GET', json: [{ role: 'user', text: '历史问题' }, { role: 'model', text: '历史回答' }] },
        { match: '^/api/conversations/[^/]+$', method: 'PUT', json: { ok: true } },
        { match: '^/api/conversations/[^/]+$', method: 'DELETE', json: { ok: true } },
        { match: '^/api/conversations$', method: 'POST', json: { id: 'conv-new' } },
        { match: '^/api/conversations$', method: 'GET', json: [{ id: 'conv-prev', title: '历史对话', updated_at: '2026-06-10 09:00:00' }] },
        { match: '/api/ai/agent-chat', json: { text: 'ok.' } },
      ],
    });
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));

    // helpers: read the browser-recorded rename/delete IPC calls
    const recordedByMethod = (method: string) => page.evaluate((m) => ((window as any).__calls || [])
      .filter((c: any) => c.channel === 'api:request' && c.method === m && /^\/api\/conversations\/[^/]+$/.test(String(c.path || '').split('?')[0])), method);

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
    await expect.poll(async () => (await recordedByMethod('PUT')).length, { timeout: 10_000 }).toBeGreaterThanOrEqual(1);
    const renames = await recordedByMethod('PUT');
    expect(renames[0]?.path).toContain('conv-prev');
    expect(renames[0]?.body?.title).toBe('改名了');

    // (4) two-click delete → DELETE /api/conversations/conv-prev
    await page.getByTitle(loc.chat.deleteConversation).first().click();
    await page.getByText(loc.chat.deleteConfirm).first().click();
    await expect.poll(async () => (await recordedByMethod('DELETE')).length, { timeout: 10_000 }).toBeGreaterThanOrEqual(1);
    expect((await recordedByMethod('DELETE'))[0]?.path).toContain('conv-prev');

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
      await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
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
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
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
    await gotoApp(page, 'ja'); // Phase 3 PR-3.7: test injects its own electronAPI
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
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
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
      await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
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
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
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
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
    await page.locator('nav i.fa-file-contract').first().click();
    await page.locator('button:has(i.fa-plus)').first().click();
    await expect(page.locator('input[name="docNumber"]')).toHaveValue('QT-2026-0001', { timeout: 10_000 });

    // switch to statement → generator appears; the two trim-variants collapse to ONE option
    await page.locator('select[name="docType"]').selectOption('statement');
    await expect(page.locator('select[name="stmtCustomer"]')).toBeVisible({ timeout: 10_000 });
    // Wait for the async-populated options to render before asserting the dedup count
    // (web-first toHaveCount retries; a bare .count() snapshot races the option render).
    await expect(page.locator('select[name="stmtCustomer"] option').filter({ hasText: '对账客户' })).toHaveCount(1, { timeout: 10_000 });

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
      await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
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
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
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
    await gotoApp(page, ui); // Phase 3 PR-3.7: test injects its own electronAPI
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

// ───────────────────────────────────────────────────────────────────────────
// PR-T2: App.tsx trusts the backend financial statement verbatim — it must NOT
// re-apply a hardcoded 25% income tax / 12% surcharge. The dashboard profit-
// margin widget recomputes net margin from the passed fields (using the backend
// incomeTax), so a backend incomeTax that is NOT 25% of profit (CN) or is 0 (JP)
// proves the client override is gone. (US is intentionally covered via JP: the US
// dashboard is Schedule-C-card-driven and renders report.scheduleC, not the
// enriched financialStatement, so the override never reached a US-visible surface
// — only the AI data feed. The guard check:hardcoded-rates + these tests lock the
// shared, locale-agnostic code path that also serves US.) The net-margin value is
// the `span.text-emerald-500.font-bold.text-xl` containing '%' in ProfitMarginIndicators.
// ───────────────────────────────────────────────────────────────────────────
async function bootDashboardWithFS(
  page: import('@playwright/test').Page,
  ui: string,
  acc: string,
  financialStatement: Record<string, number>,
) {
  // Phase 3 PR-3.6: IPC-boot with a custom dashboard financialStatement (no call
  // recording in this group, so a straight bootComboIPC suffices).
  await bootComboIPC(page, ui, acc, { dashboard: { ...DASHBOARD(acc), locale: acc, financialStatement } });
  await page.waitForTimeout(500);
}

test.describe('PR-T2 → App.tsx trusts backend financial statement (no client tax-rate math)', () => {
  // The net-margin value is the only emerald `text-xl font-bold` span containing
  // '%' (gross margin is text-primary; other emerald spans are money totals).
  const netMargin = (page: import('@playwright/test').Page) =>
    page.locator('span.text-emerald-500.font-bold.text-xl').filter({ hasText: '%' });

  test('CN: backend income tax (not 25%) flows through to the dashboard net margin', async ({ page }) => {
    // revenue 100000 − cost 60000 = 40000 gross. Backend income tax = 2000 (e.g. a
    // small-business ~5% estimate, NOT 25%) → net 38000 → net margin 38%.
    // Pre-fix, App.tsx forced 25% → income tax 10000 → net margin 30%.
    await bootDashboardWithFS(page, 'zh-CN', 'CN', {
      salesRevenue: 100000, costOfSales: 60000, taxSurcharge: 0, shippingFee: 0,
      adminExpense: 0, incomeTax: 2000, grossProfit: 40000, grossMargin: 40,
      netProfit: 38000, netMargin: 38,
    });
    await expect(netMargin(page)).toHaveText('38%', { timeout: 10_000 });
    await expect(page.getByText('30%')).toHaveCount(0); // not the 25%-override value
  });

  test('JP: income tax is not force-applied at 25% (zero-tax case flows through)', async ({ page }) => {
    // JP renders ProfitMarginIndicators from financialStatement (US is Schedule-C-
    // card-driven and does not surface it — see file header). Backend income tax = 0
    // → net margin = gross margin = 40%. Pre-fix, App.tsx forced 25% → net 30%.
    await bootDashboardWithFS(page, 'ja', 'JP', {
      salesRevenue: 100000, costOfSales: 60000, taxSurcharge: 0, shippingFee: 0,
      adminExpense: 0, incomeTax: 0, grossProfit: 40000, grossMargin: 40,
      netProfit: 40000, netMargin: 40,
    });
    await expect(netMargin(page)).toHaveText('40%', { timeout: 10_000 });
    await expect(page.getByText('30%')).toHaveCount(0); // not the 25%-override value
  });

  // PR-T5-2A: costOfSales is now COGS-only; the dashboard recompute must subtract
  // operatingExpenses, so net margin reflects it. Pre-flip (no operating subtraction)
  // this fixture would show a 60% net margin instead of 40%.
  test('T5-2A: dashboard net margin subtracts operating expenses (COGS-only costOfSales)', async ({ page }) => {
    await bootDashboardWithFS(page, 'zh-CN', 'CN', {
      salesRevenue: 100000, costOfSales: 40000, costOfGoodsSold: 40000, operatingExpenses: 20000,
      operatingProfit: 40000, taxSurcharge: 0, shippingFee: 0, adminExpense: 0, incomeTax: 0,
      grossProfit: 60000, grossMargin: 60, netProfit: 40000, netMargin: 40,
    });
    await expect(netMargin(page)).toHaveText('40%', { timeout: 10_000 }); // net = revenue − COGS − operating
    await expect(page.getByText('60%')).toBeVisible(); // gross margin = revenue − COGS
  });
});

// ───────────────────────────────────────────────────────────────────────────
// PR-T5-2B-2: CategoriesSection is_cogs toggle + batch recategorize panel, and
// the TransactionsPage expense smart-default. Web build → HTTP route mocking;
// updateCategory / recategorize calls are recorded Node-side to assert payloads.
// A commit failure is surfaced as a generic retry message — the UI must NOT rely
// on err.status (Electron IPC strips it), so the mock REJECTS the commit without a
// usable status and we assert the retry copy still shows.
// Phase 3 PR-3.7: IPC-boot. recategorize is body-dependent (dryRun preview vs commit)
// and the commit-fail path rejects; the recat / updateCategory calls are recorded
// browser-side (window.__calls) and read back via page.evaluate.
// ───────────────────────────────────────────────────────────────────────────
const RECAT_CATS = (acc: string) => ([
  { id: 'c-cogs', locale: acc, type: 'expense', slug: 'cogs', label_zh_cn: '营业成本', label_zh_tw: '營業成本', label_en: 'COGS Cat', label_ja: '売上原価', label_ko: '매출원가', label_fr: 'COGS Cat', schedule_line: null, is_deductible: true, deductible_pct: 100, is_cogs: true, parent_id: null, sort_order: 10, is_system: true, displayLabel: 'COGS Cat' },
  { id: 'c-op', locale: acc, type: 'expense', slug: 'admin', label_zh_cn: '管理费用', label_zh_tw: '管理費用', label_en: 'Op Cat', label_ja: '一般管理費', label_ko: '관리비', label_fr: 'Op Cat', schedule_line: null, is_deductible: true, deductible_pct: 100, is_cogs: false, parent_id: null, sort_order: 20, is_system: true, displayLabel: 'Op Cat' },
]);

async function bootRecat(page: import('@playwright/test').Page, ui: string, acc: string, opts: { commitFails?: boolean } = {}) {
  const commitResp = opts.commitFails
    ? { match: '/api/transactions/recategorize', method: 'POST', bodyMatch: { dryRun: false }, reject: 'boom' }
    : { match: '/api/transactions/recategorize', method: 'POST', bodyMatch: { dryRun: false }, json: { dryRun: false, fromCategoryId: 'c-cogs', toCategoryId: 'c-op', moved: 3 } };
  await bootComboIPC(page, ui, acc, {
    recordCalls: true,
    apiResponses: [
      { match: '/api/transactions/recategorize', method: 'POST', bodyMatch: { dryRun: true }, json: { dryRun: true, fromCategoryId: 'c-cogs', toCategoryId: 'c-op', affected: 3 } },
      commitResp,
      { match: '/api/transactions/summary', json: { income: { total: 0, count: 0 }, expense: { total: 0, count: 0 }, net: 0 } },
      { match: '^/api/categories/[^/]+$', method: 'PUT', json: { success: true } },
      { match: '^/api/categories$', method: 'GET', json: RECAT_CATS(acc) },
    ],
  });
}

// Read the browser-recorded recategorize / updateCategory IPC calls (Phase 3 PR-3.7).
const recatRecorded = (page: import('@playwright/test').Page) =>
  page.evaluate(() => ((window as any).__calls || []).filter((c: any) => c.channel === 'api:request' && c.method === 'POST' && /\/api\/transactions\/recategorize/.test(String(c.path || '').split('?')[0])));
const catUpdatesRecorded = (page: import('@playwright/test').Page) =>
  page.evaluate(() => ((window as any).__calls || []).filter((c: any) => c.channel === 'api:request' && c.method === 'PUT' && /^\/api\/categories\/[^/]+$/.test(String(c.path || '').split('?')[0])));

const recatLoc = (ui: string) => JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8')).settings.categories;
const withCount = (s: string, n: number) => s.replace('{{count}}', String(n));

test.describe('PR-T5-2B-2 → categories is_cogs + recategorize UI', () => {
  test('CN: recategorize preview → confirm, and is_cogs toggle calls updateCategory', async ({ page }) => {
    const ui = 'zh-CN';
    await bootRecat(page, ui, 'CN');
    const c = recatLoc(ui);
    await page.locator('i.fa-cog').first().click();
    await page.locator('button:has(i.fa-tags)').click();
    await expect(page.getByText(c.cogsHeader)).toBeVisible({ timeout: 10_000 });

    // Recategorize: from = COGS cat, to = operating cat (recat selects are #2/#3;
    // #1 is the locale switcher). Preview → "将移动 3 笔交易", confirm → "已移动 3 笔".
    // The two recat selects are the only ones carrying the c-cogs option (the
    // locale switcher does not), so filter on it rather than a fragile nth index.
    const recatSelects = page.locator('select').filter({ has: page.locator('option[value="c-cogs"]') });
    await recatSelects.nth(0).selectOption('c-cogs');
    await recatSelects.nth(1).selectOption('c-op');
    await page.getByRole('button', { name: c.recatPreview }).click();
    await expect(page.getByText(withCount(c.recatWillMove, 3))).toBeVisible({ timeout: 10_000 });
    await expect.poll(async () => (await recatRecorded(page)).some((r: any) => r.body?.dryRun === true), { timeout: 10_000 }).toBe(true);
    await page.getByRole('button', { name: c.recatConfirm }).click();
    await expect(page.getByText(withCount(c.recatMoved, 3))).toBeVisible({ timeout: 10_000 });
    // commit carried expectedAffected = previewed count
    await expect.poll(async () => (await recatRecorded(page)).some((r: any) => r.body?.dryRun === false && r.body?.expectedAffected === 3), { timeout: 10_000 }).toBe(true);

    // is_cogs toggle: click the operating category's badge → updateCategory({is_cogs})
    await page.getByRole('button', { name: c.operatingBadge }).first().click();
    await expect.poll(async () => (await catUpdatesRecorded(page)).length, { timeout: 10_000 }).toBeGreaterThan(0);
    expect((await catUpdatesRecorded(page)).some((u: any) => typeof u.body?.is_cogs === 'boolean')).toBeTruthy();
  });

  test('CN: commit failure shows the retry message (no reliance on err.status)', async ({ page }) => {
    const ui = 'zh-CN';
    await bootRecat(page, ui, 'CN', { commitFails: true });
    const c = recatLoc(ui);
    await page.locator('i.fa-cog').first().click();
    await page.locator('button:has(i.fa-tags)').click();
    // The two recat selects are the only ones carrying the c-cogs option (the
    // locale switcher does not), so filter on it rather than a fragile nth index.
    const recatSelects = page.locator('select').filter({ has: page.locator('option[value="c-cogs"]') });
    await recatSelects.nth(0).selectOption('c-cogs');
    await recatSelects.nth(1).selectOption('c-op');
    await page.getByRole('button', { name: c.recatPreview }).click();
    await expect(page.getByText(withCount(c.recatWillMove, 3))).toBeVisible({ timeout: 10_000 });
    await page.getByRole('button', { name: c.recatConfirm }).click();
    await expect(page.getByText(c.recatRetryPreview)).toBeVisible({ timeout: 10_000 });
  });

  test('CN: new expense defaults to the operating (non-COGS) category', async ({ page }) => {
    const ui = 'zh-CN';
    await bootRecat(page, ui, 'CN');
    await page.locator('i.fa-exchange-alt').first().click(); // → Transactions page
    await page.locator('button:has(i.fa-plus)').first().click(); // → new-transaction form
    // the category <select> (it carries the c-cogs/c-op options) defaults to operating
    await expect(page.locator('select:has(option[value="c-op"])')).toHaveValue('c-op', { timeout: 10_000 });
  });

  test('US: recategorize panel + cost-type column are hidden', async ({ page }) => {
    const ui = 'en';
    await bootRecat(page, ui, 'US');
    const c = recatLoc(ui);
    await page.locator('i.fa-cog').first().click();
    await page.locator('button:has(i.fa-tags)').click();
    await page.waitForTimeout(500);
    await expect(page.getByText(c.recatTitle)).toHaveCount(0);
    await expect(page.getByText(c.cogsHeader)).toHaveCount(0);
  });
});

// ── §2A PR-2b: disk-full / fs write errors surface actionable systemError.* text ──
// When a CRUD save rejects with the backend AI_ERR:SQLITE_FULL wrapper, getSystemErrorText
// upgrades the generic "save failed" to the localized systemError.diskFull message.
// One B-class page (Products, setError → DOM, also fixes the raw-AI_ERR leak) + one
// A-class page (Purchase, alert). Regime-neutral feature → one ui×acc combo suffices.
test.describe('§2A disk-full surfaced in CRUD pages (PR-2b)', () => {
  const ui = 'zh-CN';
  const SQLITE_FULL = 'AI_ERR:SQLITE_FULL · HTTP 0 (database or disk is full)';

  test('B-class: Products create reject → systemError.diskFull (setError, no AI_ERR leak)', async ({ page }) => {
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await bootComboIPC(page, ui, 'CN', {
      apiResponses: [{ match: '/api/products', method: 'POST', reject: SQLITE_FULL }],
    });
    // Settings → Products/Services sub-tab (stable icons: fa-cog → fa-box)
    await page.locator('i.fa-cog').first().click();
    await page.locator('button:has(i.fa-box)').click();
    // open add form, fill name, save → POST /api/products rejects with the disk-full code
    await page.getByRole('button', { name: loc.products.addButton }).click();
    await page.getByPlaceholder(loc.products.namePlaceholder).fill('Disk Full Test');
    await page.getByRole('button', { name: loc.common.save, exact: true }).click();
    // surfaces the actionable disk-full message, NOT the raw AI_ERR technical string
    await expect(page.getByText(loc.systemError.diskFull)).toBeVisible({ timeout: 10_000 });
    const body = await page.locator('body').innerText();
    expect(body, 'raw AI_ERR string must not leak to the user').not.toContain('AI_ERR');
  });

  test('A-class: Purchase save reject → systemError.diskFull (alert)', async ({ page }) => {
    const loc = JSON.parse(fs.readFileSync(path.join('i18n', 'locales', `${ui}.json`), 'utf8'));
    await bootComboIPC(page, ui, 'CN', {
      apiResponses: [{ match: '/api/purchases', method: 'POST', reject: SQLITE_FULL }],
    });
    let dialogMsg: string | null = null;
    page.on('dialog', async (d) => { dialogMsg = d.message(); await d.dismiss(); });
    // 采购页 → 新增记录 modal (stable icons: fa-file-import → fa-plus)
    await page.locator('i.fa-file-import').first().click();
    await page.locator('button:has(i.fa-plus)').first().click();
    // fill all HTML5-required fields (date is pre-filled with today): supplier + quantity + amount
    await page.locator('[data-testid="ocr-fill-counterparty"]').fill('Acme');
    await page.getByPlaceholder(loc.purchases.formQuantityPlaceholder).fill('10');
    await page.locator('input[type="number"][required]').fill('100');
    await page.getByRole('button', { name: loc.purchases.formSubmit }).click();
    // the rejected save alerts the actionable disk-full message
    await expect.poll(() => dialogMsg, { timeout: 10_000 }).toBe(loc.systemError.diskFull);
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
