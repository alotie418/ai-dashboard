import { defineConfig } from '@playwright/test';

// Real-Electron e2e config (PR-1). Independent from the page-level locale-matrix
// suite (playwright.config.ts): a SEPARATE testDir so the default `playwright test`
// (npm run test:locale-ui) never picks these up, and vice-versa.
//
// These specs boot the ACTUAL Electron main process via _electron.launch and drive
// the real router.dispatch / real better-sqlite3 through electronApp.evaluate(). They
// never use the page/context/browser fixtures, so NO Chromium is launched and there
// is NO webServer (the SPA / dist is not needed — we don't enter the renderer layer).
//
// Deliberately NOT wired into check:all: the real-Electron path needs better-sqlite3
// built for the ELECTRON node ABI (npm run electron:rebuild), which is the opposite of
// what the node-ABI handler/migration guards need. Keep it a manual / dedicated job.
export default defineConfig({
  testDir: './e2e-electron',
  outputDir: 'test-results/electron/_artifacts',
  timeout: 60_000,
  fullyParallel: false,
  workers: 1, // a single Electron instance at a time; specs share one launch per file
  retries: 0,
  reporter: [['list']],
});
