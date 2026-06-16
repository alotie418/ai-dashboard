// Real-Electron e2e — attachment file IPC channels (PR-2).
//
// Covers the three ipcMain.handle closures that PR-1 could not reach (they are inline,
// not exported, so only reachable via the renderer's window.electronAPI.invoke):
//   • app:pickDocAttachment   — dialog.showOpenDialog → validate → copy into userData
//   • app:openDocAttachment   — resolve + exists → shell.openPath
//   • app:discardDocAttachment — resolve + DB reference guard → safeDeleteAttachment
//
// Driven through a minimal about:blank page that has the REAL electron/preload.js
// attached (openPreloadPage). dialog.showOpenDialog and shell.openPath are stubbed by
// monkeypatching the live electron singletons (the handlers read the same singletons).
// Source files are generated at runtime in a temp SOURCE dir (separate from userData;
// oversized via sparse truncate); attachment copies/deletes happen in the isolated temp
// userData. No SPA/dist, no main.js/preload.js changes, no production code touched.

import { test, expect } from '@playwright/test';
import type { ElectronApplication, Page } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { launchApp, disposeApp, waitForReady, type LaunchedApp } from './helpers/launch';
import {
  openPreloadPage, invokeViaPage, stubOpenDialog, stubShellOpenPath, readShellOpenPathCalls,
  dispatchInMain, seedAttachment, attachmentExists, resolveAttachmentAbs, listDocsFiles,
} from './helpers/ipc';

let app: LaunchedApp | undefined;
let electronApp: ElectronApplication;
let page: Page;

// Runtime-generated source fixtures (NOT committed; live under a temp source dir).
let srcDir: string;
let srcPdf: string, srcPng: string, srcTxt: string, srcHuge: string;

const pick = (args: any) => invokeViaPage<{ ok: boolean; relPath?: string; fileName?: string; error?: string }>(page, 'app:pickDocAttachment', args);
const open = (args: any) => invokeViaPage<{ ok: boolean; error?: string }>(page, 'app:openDocAttachment', args);
const discard = (args: any) => invokeViaPage<{ ok: boolean; error?: string }>(page, 'app:discardDocAttachment', args);

test.beforeAll(async () => {
  app = await launchApp();
  electronApp = app.electronApp;
  await waitForReady(app);
  page = await openPreloadPage(electronApp);

  srcDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sololedger-e2e-src-'));
  srcPdf = path.join(srcDir, 'valid.pdf');
  srcPng = path.join(srcDir, 'valid.png');
  srcTxt = path.join(srcDir, 'invalid.txt');
  srcHuge = path.join(srcDir, 'huge.pdf');
  fs.writeFileSync(srcPdf, '%PDF-1.4 e2e');
  fs.writeFileSync(srcPng, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  fs.writeFileSync(srcTxt, 'not an allowed type');
  // Sparse 21MB (> 20MB cap) — logical size only, no real 21MB write.
  fs.writeFileSync(srcHuge, '');
  fs.truncateSync(srcHuge, 21 * 1024 * 1024);
});

test.afterAll(async () => {
  await disposeApp(app);
  try { fs.rmSync(srcDir, { recursive: true, force: true }); } catch { /* best-effort */ }
});

test('smoke: preload page can invoke api:request through the real bridge', async () => {
  const settings = await invokeViaPage<any>(page, 'api:request', { method: 'GET', path: '/api/settings' });
  expect(settings.accounting_locale).toBe('CN');
});

// ───────────────────────── pickDocAttachment ─────────────────────────

test('pick: user cancels → ok:false, no file produced', async () => {
  await stubOpenDialog(electronApp, { canceled: true, filePaths: [] });
  const before = (await listDocsFiles(electronApp)).length;
  const r = await pick({ docId: 'e2e-cancel' });
  expect(r.ok).toBe(false);
  expect((await listDocsFiles(electronApp)).length).toBe(before);
});

test('pick: valid pdf → copied into userData/attachments/docs, safe relPath + fileName', async () => {
  await stubOpenDialog(electronApp, { canceled: false, filePaths: [srcPdf] });
  const r = await pick({ docId: 'e2e-pdf' });
  expect(r.ok).toBe(true);
  expect(r.relPath).toMatch(/^attachments\/docs\/[A-Za-z0-9][A-Za-z0-9._-]*\.pdf$/);
  expect(r.fileName).toBe('valid.pdf');
  expect(await attachmentExists(electronApp, r.relPath!)).toBe(true);
});

test('pick: valid png → ok and file exists', async () => {
  await stubOpenDialog(electronApp, { canceled: false, filePaths: [srcPng] });
  const r = await pick({ docId: 'e2e-png' });
  expect(r.ok).toBe(true);
  expect(r.relPath).toMatch(/\.png$/);
  expect(r.fileName).toBe('valid.png');
  expect(await attachmentExists(electronApp, r.relPath!)).toBe(true);
});

test('pick: invalid txt → INVALID_FILE_TYPE, no copy', async () => {
  await stubOpenDialog(electronApp, { canceled: false, filePaths: [srcTxt] });
  const before = (await listDocsFiles(electronApp)).length;
  const r = await pick({ docId: 'e2e-txt' });
  expect(r.ok).toBe(false);
  expect(r.error).toBe('INVALID_FILE_TYPE');
  expect((await listDocsFiles(electronApp)).length).toBe(before);
});

test('pick: oversized (>20MB) → FILE_TOO_LARGE, no copy', async () => {
  await stubOpenDialog(electronApp, { canceled: false, filePaths: [srcHuge] });
  const before = (await listDocsFiles(electronApp)).length;
  const r = await pick({ docId: 'e2e-huge' });
  expect(r.ok).toBe(false);
  expect(r.error).toBe('FILE_TOO_LARGE');
  expect((await listDocsFiles(electronApp)).length).toBe(before);
});

// ───────────────────────── openDocAttachment ─────────────────────────

test('open: valid existing relPath → ok, shell.openPath gets the resolved abs path', async () => {
  const rel = await seedAttachment(electronApp, 'open-valid.pdf', 'X');
  const abs = await resolveAttachmentAbs(electronApp, rel);
  await stubShellOpenPath(electronApp, '');
  const r = await open({ relPath: rel });
  expect(r.ok).toBe(true);
  expect(await readShellOpenPathCalls(electronApp)).toEqual([abs]);
});

test('open: invalid relPath → INVALID_PATH, shell.openPath not called', async () => {
  await stubShellOpenPath(electronApp, '');
  const r = await open({ relPath: '../outside.pdf' });
  expect(r.ok).toBe(false);
  expect(r.error).toBe('INVALID_PATH');
  expect(await readShellOpenPathCalls(electronApp)).toEqual([]);
});

test('open: valid-format relPath but file missing → ATTACHMENT_NOT_FOUND', async () => {
  await stubShellOpenPath(electronApp, '');
  const r = await open({ relPath: 'attachments/docs/open-missing.pdf' });
  expect(r.ok).toBe(false);
  expect(r.error).toBe('ATTACHMENT_NOT_FOUND');
  expect(await readShellOpenPathCalls(electronApp)).toEqual([]);
});

test('open: shell.openPath returns an error string → OPEN_FAILED', async () => {
  const rel = await seedAttachment(electronApp, 'open-fail.pdf', 'X');
  await stubShellOpenPath(electronApp, 'kLSServerCommunicationErr');
  const r = await open({ relPath: rel });
  expect(r.ok).toBe(false);
  expect(r.error).toBe('OPEN_FAILED');
});

// ───────────────────────── discardDocAttachment ─────────────────────────

test('discard: valid unreferenced file → ok, file deleted', async () => {
  const rel = await seedAttachment(electronApp, 'discard-ok.pdf', 'X');
  expect(await attachmentExists(electronApp, rel)).toBe(true);
  const r = await discard({ relPath: rel });
  expect(r.ok).toBe(true);
  expect(await attachmentExists(electronApp, rel)).toBe(false);
});

test('discard: referenced by a document → ATTACHMENT_IN_USE, file preserved', async () => {
  const rel = await seedAttachment(electronApp, 'discard-inuse.pdf', 'X');
  const created = await dispatchInMain(electronApp, {
    method: 'POST', path: '/api/documents',
    body: { doc_type: 'quotation', doc_number: 'E2E-IPC-DISCARD', customer_name: 'C', doc_date: '2026-01-01' },
  });
  await dispatchInMain(electronApp, {
    method: 'PUT', path: `/api/documents/${created.id}/tax-invoice`,
    body: { tax_invoice_attachment_path: rel },
  });
  const r = await discard({ relPath: rel });
  expect(r.ok).toBe(false);
  expect(r.error).toBe('ATTACHMENT_IN_USE');
  expect(await attachmentExists(electronApp, rel)).toBe(true);
});

test('discard: invalid relPath → INVALID_PATH', async () => {
  const r = await discard({ relPath: '../escape.pdf' });
  expect(r.ok).toBe(false);
  expect(r.error).toBe('INVALID_PATH');
});
