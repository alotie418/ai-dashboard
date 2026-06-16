// Helpers for the attachment-IPC e2e suite (PR-2).
//
// The three attachment channels (app:pickDocAttachment / openDocAttachment /
// discardDocAttachment) are ipcMain.handle INLINE CLOSURES — not exported, so they
// can't be reached the PR-1 way (electronApp.evaluate → router.dispatch). The only
// caller path is the renderer's window.electronAPI.invoke (preload). So we spin up a
// minimal about:blank page WITH electron/preload.js attached and drive invoke() from it.
// No SPA / dist needed — the handlers never touch the DOM.
//
// Two evaluate idioms (both validated in PR-1):
//   • electron singletons (dialog/shell/BrowserWindow) come from the evaluate FIRST ARG
//     (the electron module). Monkeypatching dialog.showOpenDialog / shell.openPath on
//     those singletons is seen by the handlers, which read the SAME singletons at call
//     time (dialog via the registerHandlers closure; shell via require('electron')).
//   • project modules (router/db/attachments) are reached via
//     process.getBuiltinModule('module').createRequire(main.js) — the eval realm has no
//     `require`/dynamic-import; absolute paths hit the cached singletons main.js loaded.

import type { ElectronApplication, Page } from '@playwright/test';
import path from 'node:path';
import { PROJECT_ROOT } from './launch';

/** Absolute path to the REAL preload — same file main.js uses. */
export const PRELOAD_PATH = path.join(PROJECT_ROOT, 'electron', 'preload.js');

/** Create an about:blank window with the real preload and return it as a Playwright Page.
 *
 *  Uses waitForEvent('window') (NOT firstWindow(), which is main.js's failed-load window).
 *  main.js ALSO creates a window (loadURL localhost:3000 → fails, never exposes electronAPI);
 *  whether ITS 'window' event reaches our waitForEvent is a delivery-timing race, so a plain
 *  waitForEvent is flaky — it sometimes captures main's window. The predicate fixes that: it
 *  accepts only the page where contextBridge actually exposed electronAPI (ours), skipping
 *  main's failed-load window. (Predicate keeps consuming events until one returns truthy.) */
export async function openPreloadPage(electronApp: ElectronApplication): Promise<Page> {
  const pagePromise = electronApp.waitForEvent('window', {
    predicate: async (p) => {
      try {
        await p.waitForFunction(() => !!(window as any).electronAPI, undefined, { timeout: 3_000 });
        return true;
      } catch {
        return false; // main's failed-load window: no electronAPI → skip, wait for ours
      }
    },
    timeout: 30_000,
  });
  await electronApp.evaluate(({ BrowserWindow }, preload) => {
    const w = new BrowserWindow({
      show: false,
      webPreferences: {
        preload,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: false, // preload uses require('electron'); must match main.js
      },
    });
    return w.loadURL('about:blank');
  }, PRELOAD_PATH);
  return pagePromise;
}

/** Invoke any IPC channel through the renderer's electronAPI (the real preload bridge). */
export function invokeViaPage<T = any>(page: Page, channel: string, payload?: any): Promise<T> {
  return page.evaluate(
    ([ch, pl]) => (window as any).electronAPI.invoke(ch as string, pl),
    [channel, payload] as const,
  );
}

/** Stub dialog.showOpenDialog on the live electron singleton (next pick uses this result). */
export async function stubOpenDialog(
  electronApp: ElectronApplication,
  result: { canceled: boolean; filePaths: string[] },
): Promise<void> {
  await electronApp.evaluate(({ dialog }, ret) => {
    (dialog as any).showOpenDialog = async () => ret;
  }, result);
}

/** Stub shell.openPath on the live singleton; resets a global call-log read back later. */
export async function stubShellOpenPath(electronApp: ElectronApplication, returnValue: string): Promise<void> {
  await electronApp.evaluate(({ shell }, ret) => {
    (globalThis as any).__openPathCalls = [];
    (shell as any).openPath = async (p: string) => {
      (globalThis as any).__openPathCalls.push(p);
      return ret;
    };
  }, returnValue);
}

/** The paths shell.openPath was invoked with since the last stubShellOpenPath. */
export function readShellOpenPathCalls(electronApp: ElectronApplication): Promise<string[]> {
  return electronApp.evaluate(() => (globalThis as any).__openPathCalls || []);
}

/** Run the real router.dispatch in the main process (for the discard reference-guard setup). */
export function dispatchInMain(electronApp: ElectronApplication, request: { method: string; path: string; body?: any }): Promise<any> {
  return electronApp.evaluate((_e, { root, req }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    return r(root + '/electron/handlers/router.js').dispatch(req);
  }, { root: PROJECT_ROOT, req: request });
}

/** Write a file straight into the real attachments/docs/ root; returns its relPath. */
export function seedAttachment(electronApp: ElectronApplication, name: string, content: string): Promise<string> {
  return electronApp.evaluate((_e, { root, fileName, data }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const fs = r('node:fs');
    const path = r('node:path');
    const dir = r(root + '/electron/handlers/attachments.js').getDocsAttachmentsRoot();
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, fileName), data);
    return `attachments/docs/${fileName}`;
  }, { root: PROJECT_ROOT, fileName: name, data: content });
}

/** True iff resolveAttachment(relPath) resolves AND the file exists (real fs, main process). */
export function attachmentExists(electronApp: ElectronApplication, relPath: string): Promise<boolean> {
  return electronApp.evaluate((_e, { root, rel }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const fs = r('node:fs');
    const abs = r(root + '/electron/handlers/attachments.js').resolveAttachment(rel);
    return !!abs && fs.existsSync(abs);
  }, { root: PROJECT_ROOT, rel: relPath });
}

/** resolveAttachment(relPath) → absolute path or null (to assert shell.openPath's arg). */
export function resolveAttachmentAbs(electronApp: ElectronApplication, relPath: string): Promise<string | null> {
  return electronApp.evaluate((_e, { root, rel }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    return r(root + '/electron/handlers/attachments.js').resolveAttachment(rel);
  }, { root: PROJECT_ROOT, rel: relPath });
}

/** Names currently in the attachments/docs/ root ([] if the dir doesn't exist yet). */
export function listDocsFiles(electronApp: ElectronApplication): Promise<string[]> {
  return electronApp.evaluate((_e, { root }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const fs = r('node:fs');
    const dir = r(root + '/electron/handlers/attachments.js').getDocsAttachmentsRoot();
    try { return fs.readdirSync(dir); } catch { return []; }
  }, { root: PROJECT_ROOT });
}
