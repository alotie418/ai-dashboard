import { defineConfig } from '@playwright/test';

// Page-level locale-matrix E2E. Serves the built SPA via `vite preview` and drives it
// with Playwright; /api + /auth are mocked per-combo (see e2e/locale-matrix.spec.ts) so
// the real accounting-regime tax labels render client-side without a backend/DB.
export default defineConfig({
  testDir: './e2e',
  outputDir: 'test-results/locale-matrix/_artifacts',
  timeout: 60_000,
  fullyParallel: false,
  workers: 1, // sequential so the module-level summary aggregates across all 36 combos
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:4173',
    browserName: 'chromium',
    headless: true,
    viewport: { width: 1440, height: 900 },
  },
  webServer: {
    command: 'npx vite preview --port 4173 --strictPort --host 127.0.0.1',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: true,
    timeout: 120_000,
  },
});
