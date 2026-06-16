// Shared launcher for the real-Electron e2e suite (PR-1).
//
// Boots the ACTUAL Electron main process via Playwright's _electron.launch with an
// isolated, throwaway userData directory (Chromium --user-data-dir switch). The main
// process runs its real whenReady path — initDatabase() (real better-sqlite3 in the
// temp userData) + registerHandlers() — so tests drive the real router.dispatch via
// electronApp.evaluate(). No renderer page, no preload, no dist, no dialog/shell mock.
//
// userData isolation: --user-data-dir makes app.getPath('userData') resolve under the
// temp dir, so the real sqlite file and the real attachments/docs/ tree live there and
// are deleted on teardown. We never touch the developer's real userData.
//
// Readiness (waitForReady): _electron.launch resolves as soon as the main process is up
// — BEFORE app.whenReady() has run initDatabase()/registerHandlers(). Touching the DB
// or requiring the router before then races a half-loaded module (circular-dep partial
// exports → "dispatch is not a function") or an in-flight migration ("no such table …").
// main.js prints "[handlers] registered" as the LAST step of whenReady (after migrating
// to head AND wiring the IPC routes), so we wait for that line. It also guarantees a
// later getDb() returns main's already-built handle instead of starting a SECOND
// initDatabase (which would open a competing connection). The marker is a deliberate,
// documented coupling to main.js's readiness log.
//
// ABI note: better-sqlite3 must be built for the ELECTRON node ABI for the main process
// to load it (npm run electron:rebuild). Under the plain-node ABI the main process logs
// a warning and the readiness marker still prints, but the smoke test fails fast — by
// design (see the PR validation order).

import { _electron as electron, type ElectronApplication } from '@playwright/test';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';

// e2e-electron/helpers/launch.ts → project root is two levels up.
export const PROJECT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

// Last line main.js logs at the end of registerHandlers() — our readiness signal.
const READY_MARKER = '[handlers] registered';

export type LaunchedApp = {
  electronApp: ElectronApplication;
  /** The --user-data-dir temp root; everything Electron writes lives under it. */
  userDataDir: string;
  /** Resolves once main.js has finished whenReady (migrated DB + registered IPC). */
  whenReady: Promise<void>;
};

/** Launch a fresh, isolated Electron main process. One per spec file (beforeAll). */
export async function launchApp(): Promise<LaunchedApp> {
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sololedger-e2e-'));
  // executablePath is auto-resolved by Playwright from the `electron` devDependency.
  const electronApp = await electron.launch({
    cwd: PROJECT_ROOT,
    args: [PROJECT_ROOT, `--user-data-dir=${userDataDir}`],
  });

  // Accumulate main-process stdout and flip ready when the marker appears. Attached
  // synchronously right after launch, before whenReady has had a chance to print it.
  const proc = electronApp.process();
  let buf = '';
  let markReady: () => void;
  const whenReady = new Promise<void>((resolve) => { markReady = resolve; });
  proc.stdout?.on('data', (d) => {
    buf += d.toString();
    if (buf.includes(READY_MARKER)) markReady();
  });

  return { electronApp, userDataDir, whenReady };
}

/** Block until main.js signals readiness (or throw after timeoutMs). */
export async function waitForReady(app: LaunchedApp, timeoutMs = 30_000): Promise<void> {
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`Electron main not ready (no "${READY_MARKER}" within ${timeoutMs}ms)`)),
      timeoutMs,
    );
  });
  try { await Promise.race([app.whenReady, timeout]); } finally { clearTimeout(timer!); }
}

/** Close the app and delete its temp userData (best-effort, never throws). */
export async function disposeApp(app: LaunchedApp | undefined): Promise<void> {
  if (!app) return;
  try { await app.electronApp.close(); } catch { /* already gone */ }
  try { fs.rmSync(app.userDataDir, { recursive: true, force: true }); } catch { /* best-effort */ }
}
