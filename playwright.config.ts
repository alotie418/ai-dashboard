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
  // CI-only auto-retry：偶发时序 flake 重试一次而非红整轮（降噪，不是修根因——
  // recategorize/select 默认值时序、assistant 会话历史侧栏加载时序等已知 flake 仍需单独排查）。
  // 本地保持 0：不掩盖问题，第一次失败即可见。
  retries: process.env.CI ? 1 : 0,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:4173',
    browserName: 'chromium',
    headless: true,
    viewport: { width: 1440, height: 900 },
    trace: 'on-first-retry', // 仅重试时录 trace，保留失败排查证据
  },
  webServer: {
    command: 'npx vite preview --port 4173 --strictPort --host 127.0.0.1',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: true,
    timeout: 120_000,
  },
});
