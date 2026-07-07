import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { installElectronMock, gotoApp } from './helpers/electronMock';

// ───────────────────────────────────────────────────────────────────────────
// P0-3: BYOK is NOT an entry gate. SoloLedger is local-first bookkeeping;
// the onboarding providers step offers a skip path when no provider is saved.
// Completing OR skipping the wizard stamps a local `sololedger-onboarding-done`
// flag so later boots go straight to the app (AI features guide the user to
// Settings via the existing aiError.noProvider path when no key exists).
// ───────────────────────────────────────────────────────────────────────────

const zh = JSON.parse(fs.readFileSync(path.resolve('i18n/locales/zh-CN.json'), 'utf8'));
const DONE_KEY = 'sololedger-onboarding-done';

test.describe('onboarding BYOK skip', () => {
  test('no provider: wizard providers step can be skipped into the main app', async ({ page }) => {
    await installElectronMock(page, { hasProvider: false });
    await page.addInitScript(() => { try { localStorage.setItem('sololedger-lang', 'zh-CN'); } catch { /* ignore */ } });
    await page.goto('/', { waitUntil: 'domcontentloaded' });

    // wizard shows: welcome → locale → providers
    await expect(page.getByText(zh.onboarding.welcomeTitle)).toBeVisible();
    await page.getByRole('button', { name: zh.onboarding.startConfig }).click();
    await page.getByRole('button', { name: zh.common.next, exact: true }).click();

    // providers step: with zero saved keys the primary button stays disabled,
    // but the skip path is offered
    await expect(page.getByRole('button', { name: zh.onboarding.atLeastOneRequired })).toBeDisabled();
    await page.getByRole('button', { name: zh.onboarding.skipProviders }).click();

    // company step → skip company → main app sidebar
    await page.getByRole('button', { name: zh.onboarding.skipCompany }).click();
    await expect(page.locator('nav')).toBeVisible({ timeout: 20_000 });

    // completion (via skip) is persisted so the wizard won't re-block next boot
    expect(await page.evaluate((k) => localStorage.getItem(k), DONE_KEY)).toBe('1');
  });

  test('no provider but done-flag present: boots straight into the app', async ({ page }) => {
    await installElectronMock(page, { hasProvider: false });
    await page.addInitScript((k) => { try { localStorage.setItem(k as string, '1'); } catch { /* ignore */ } }, DONE_KEY);
    await gotoApp(page, 'zh-CN'); // waits for the sidebar <nav>
    await expect(page.getByText(zh.onboarding.welcomeTitle)).toHaveCount(0);
  });

  test('provider already configured: boots straight into the app (unchanged flow)', async ({ page }) => {
    await installElectronMock(page, { hasProvider: true });
    await gotoApp(page, 'zh-CN');
    await expect(page.getByText(zh.onboarding.welcomeTitle)).toHaveCount(0);
    // hasAny=true also stamps the flag: removing all keys later must not
    // drag an existing user back into the first-run wizard
    expect(await page.evaluate((k) => localStorage.getItem(k), DONE_KEY)).toBe('1');
  });
});
