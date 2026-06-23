import { defineConfig } from '@playwright/test';

// UI-audit smoke harness config. Reuses the same vite-preview server + Chromium +
// 1440×900 viewport as the locale-matrix suite, but scopes testDir to e2e/audit so
// it never picks up the locale-matrix specs (and the main playwright.config.ts
// ignores **/audit/** so `test:locale-ui` never picks up THIS spec). Driven by the
// scripts/audit-locale-ui.mjs wrapper (npm run audit:locale-ui:smoke).
export default defineConfig({
  testDir: './e2e/audit',
  outputDir: 'test-results/ui-audit/_artifacts',
  timeout: 120_000,
  fullyParallel: false,
  workers: 1, // sequential so the module-level findings + report aggregate across all combos
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:4173',
    browserName: 'chromium',
    headless: true,
    viewport: { width: 1440, height: 900 },
    trace: 'on-first-retry',
  },
  webServer: {
    command: 'npx vite preview --port 4173 --strictPort --host 127.0.0.1',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: true,
    timeout: 120_000,
  },
});
