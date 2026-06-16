// Real-Electron e2e — documents.js safeDeleteAttachment fs branches (PR-1).
//
// Closes the two branches §2B Batch 8 deliberately left for real Electron (they call
// safeDeleteAttachment → resolveAttachment → app.getPath('userData'), undefined under
// plain node, so the node handler harness could not exercise them):
//   A. updateTaxInvoice replacing an existing attachment_path → old file deleted.
//   B. updateTaxInvoice clearing an existing attachment_path (null) → old file deleted.
//   C. remove() on a document carrying tax_invoice_attachment_path → file deleted.
//   D. control: the FIRST set (oldPathToDelete === null) deletes nothing, incl. unrelated files.
//
// Everything runs in the REAL main process: real router.dispatch, real better-sqlite3
// in an isolated temp userData, REAL fs. We do NOT enter pick/open/discard, do NOT mock
// dialog.showOpenDialog / shell.openPath, and do NOT load the renderer/dist.
//
// Module access inside evaluate(): Playwright runs the evaluated function in the main
// process in a UtilityScript realm that has neither a `require` in scope, a usable
// process.mainModule (the ESM entry leaves require.main unset), nor a dynamic import()
// callback. We reach the CJS loader through process.getBuiltinModule('module')
// (Electron 33 / Node 20.18+) and createRequire anchored at main.js; requiring project
// modules by absolute path returns the SAME cached singletons main.js already loaded —
// so getDb()/dispatch hit the live, migrated DB. waitForReady() in beforeAll guarantees
// those singletons are fully loaded and the DB is migrated before any scenario runs.
//
// Attachment files are written directly into the real attachments/docs/ root (resolved
// inside the main process via getDocsAttachmentsRoot, so it always matches whatever
// userData Electron chose). Relative paths use the attachments/docs/<name> shape that
// satisfies attachments.js REL_RE.

import { test, expect } from '@playwright/test';
import type { ElectronApplication } from '@playwright/test';
import fs from 'node:fs';
import { launchApp, disposeApp, waitForReady, PROJECT_ROOT, type LaunchedApp } from './helpers/launch';

let app: LaunchedApp | undefined;
let electronApp: ElectronApplication;

test.beforeAll(async () => {
  app = await launchApp();
  electronApp = app.electronApp;
  await waitForReady(app);
});

test.afterAll(async () => {
  await disposeApp(app);
});

test('smoke: real main process + real sqlite + isolated userData', async () => {
  const res = await electronApp.evaluate(async ({ app: electronAppApi }, { root }) => {
    const req = process.getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const { dispatch } = req(root + '/electron/handlers/router.js');
    const dbMod = req(root + '/electron/db/index.js');
    const settings = await dispatch({ method: 'GET', path: '/api/settings', body: null });
    const db = dbMod.getDb();
    return {
      userDataPath: electronAppApi.getPath('userData'),
      dbPath: dbMod.getDbPath(),
      accountingLocale: settings && settings.accounting_locale,
      userVersion: db.pragma('user_version', { simple: true }),
      schemaVersion: dbMod.SCHEMA_VERSION,
      hasDocsTables: !!db.prepare(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name IN ('business_documents','business_document_items')"
      ).get(),
    };
  }, { root: PROJECT_ROOT });

  // Real seed (migration v3) + schema at head prove real main + real migrated sqlite.
  expect(res.accountingLocale).toBe('CN');
  expect(res.userVersion).toBe(res.schemaVersion);
  expect(res.hasDocsTables).toBe(true);
  // DB + userData live under the throwaway temp dir → isolation proven. macOS resolves
  // /var/folders → /private/var/folders, so compare against the realpath of our temp.
  const expectedRoot = fs.realpathSync(app!.userDataDir);
  expect(res.userDataPath.startsWith(expectedRoot)).toBe(true);
  expect(res.dbPath.startsWith(expectedRoot)).toBe(true);
  expect(res.dbPath.endsWith('sololedger.db')).toBe(true);
});

test('A. updateTaxInvoice replace: old attachment file is safeDeleteAttachment-deleted', async () => {
  const r = await electronApp.evaluate(async (_e, { root }) => {
    const req = process.getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const fs = req('node:fs');
    const path = req('node:path');
    const { dispatch } = req(root + '/electron/handlers/router.js');
    const { getDocsAttachmentsRoot } = req(root + '/electron/handlers/attachments.js');

    const docsRoot = getDocsAttachmentsRoot();
    fs.mkdirSync(docsRoot, { recursive: true });
    const oldName = 'old-replace-a.pdf';
    const newName = 'new-replace-a.pdf';
    const oldRel = `attachments/docs/${oldName}`;
    const newRel = `attachments/docs/${newName}`;
    const oldAbs = path.join(docsRoot, oldName);
    const newAbs = path.join(docsRoot, newName);

    fs.writeFileSync(oldAbs, 'OLD');
    const { id } = await dispatch({ method: 'POST', path: '/api/documents', body: {
      doc_type: 'quotation', doc_number: 'E2E-REPL-A', customer_name: 'C', doc_date: '2026-01-01',
    } });

    // First set: existing path was null → oldPathToDelete === null → no fs delete.
    await dispatch({ method: 'PUT', path: `/api/documents/${id}/tax-invoice`, body: { tax_invoice_attachment_path: oldRel } });
    const oldExistsAfterFirstSet = fs.existsSync(oldAbs);

    // Replace: existing path (oldRel) !== newRel → safeDeleteAttachment(oldRel).
    fs.writeFileSync(newAbs, 'NEW');
    await dispatch({ method: 'PUT', path: `/api/documents/${id}/tax-invoice`, body: { tax_invoice_attachment_path: newRel } });
    const doc = await dispatch({ method: 'GET', path: `/api/documents/${id}`, body: null });

    return {
      oldExistsAfterFirstSet,
      oldExistsAfterReplace: fs.existsSync(oldAbs),
      newExistsAfterReplace: fs.existsSync(newAbs),
      storedPath: doc.tax_invoice_attachment_path,
    };
  }, { root: PROJECT_ROOT });

  expect(r.oldExistsAfterFirstSet).toBe(true);    // first set must NOT delete
  expect(r.oldExistsAfterReplace).toBe(false);    // replace deletes the old file
  expect(r.newExistsAfterReplace).toBe(true);     // the new file survives
  expect(r.storedPath).toBe('attachments/docs/new-replace-a.pdf');
});

test('B. updateTaxInvoice clear (null): old attachment file is deleted and path cleared', async () => {
  const r = await electronApp.evaluate(async (_e, { root }) => {
    const req = process.getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const fs = req('node:fs');
    const path = req('node:path');
    const { dispatch } = req(root + '/electron/handlers/router.js');
    const { getDocsAttachmentsRoot } = req(root + '/electron/handlers/attachments.js');

    const docsRoot = getDocsAttachmentsRoot();
    fs.mkdirSync(docsRoot, { recursive: true });
    const oldName = 'old-clear-b.pdf';
    const oldRel = `attachments/docs/${oldName}`;
    const oldAbs = path.join(docsRoot, oldName);

    fs.writeFileSync(oldAbs, 'OLD');
    const { id } = await dispatch({ method: 'POST', path: '/api/documents', body: {
      doc_type: 'quotation', doc_number: 'E2E-CLR-B', customer_name: 'C', doc_date: '2026-01-01',
    } });
    await dispatch({ method: 'PUT', path: `/api/documents/${id}/tax-invoice`, body: { tax_invoice_attachment_path: oldRel } });
    const oldExistsBeforeClear = fs.existsSync(oldAbs);

    // Clear: existing (oldRel) && oldRel !== null → safeDeleteAttachment(oldRel), path → null.
    await dispatch({ method: 'PUT', path: `/api/documents/${id}/tax-invoice`, body: { tax_invoice_attachment_path: null } });
    const doc = await dispatch({ method: 'GET', path: `/api/documents/${id}`, body: null });

    return {
      oldExistsBeforeClear,
      oldExistsAfterClear: fs.existsSync(oldAbs),
      storedPath: doc.tax_invoice_attachment_path,
    };
  }, { root: PROJECT_ROOT });

  expect(r.oldExistsBeforeClear).toBe(true);
  expect(r.oldExistsAfterClear).toBe(false);      // clear deletes the old file
  expect(r.storedPath).toBeNull();                // path cleared
});

test('C. remove document carrying attachment: file is deleted and document is gone', async () => {
  const r = await electronApp.evaluate(async (_e, { root }) => {
    const req = process.getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const fs = req('node:fs');
    const path = req('node:path');
    const { dispatch } = req(root + '/electron/handlers/router.js');
    const { getDocsAttachmentsRoot } = req(root + '/electron/handlers/attachments.js');

    const docsRoot = getDocsAttachmentsRoot();
    fs.mkdirSync(docsRoot, { recursive: true });
    const name = 'old-remove-c.pdf';
    const rel = `attachments/docs/${name}`;
    const abs = path.join(docsRoot, name);

    fs.writeFileSync(abs, 'OLD');
    // Draft document (removable; remove() rejects only 'issued').
    const { id } = await dispatch({ method: 'POST', path: '/api/documents', body: {
      doc_type: 'quotation', doc_number: 'E2E-RM-C', customer_name: 'C', doc_date: '2026-01-01',
    } });
    await dispatch({ method: 'PUT', path: `/api/documents/${id}/tax-invoice`, body: { tax_invoice_attachment_path: rel } });
    const existsBeforeDelete = fs.existsSync(abs);

    // DELETE → remove() reads the row's attachment path, deletes the row, then
    // safeDeleteAttachment(path).
    await dispatch({ method: 'DELETE', path: `/api/documents/${id}`, body: null });

    let docGone = false;
    try { await dispatch({ method: 'GET', path: `/api/documents/${id}`, body: null }); }
    catch { docGone = true; }

    return { existsBeforeDelete, existsAfterDelete: fs.existsSync(abs), docGone };
  }, { root: PROJECT_ROOT });

  expect(r.existsBeforeDelete).toBe(true);
  expect(r.existsAfterDelete).toBe(false);        // remove deletes the attachment copy
  expect(r.docGone).toBe(true);                   // document row is gone
});

test('D. control: first set (oldPathToDelete null) deletes nothing — incl. unrelated files', async () => {
  const r = await electronApp.evaluate(async (_e, { root }) => {
    const req = process.getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const fs = req('node:fs');
    const path = req('node:path');
    const { dispatch } = req(root + '/electron/handlers/router.js');
    const { getDocsAttachmentsRoot } = req(root + '/electron/handlers/attachments.js');

    const docsRoot = getDocsAttachmentsRoot();
    fs.mkdirSync(docsRoot, { recursive: true });
    const firstName = 'first-control-d.pdf';
    const bystanderName = 'bystander-control-d.pdf';
    const firstRel = `attachments/docs/${firstName}`;
    const firstAbs = path.join(docsRoot, firstName);
    const bystanderAbs = path.join(docsRoot, bystanderName);

    // An unrelated file that no document references — must survive untouched.
    fs.writeFileSync(bystanderAbs, 'BYSTANDER');
    fs.writeFileSync(firstAbs, 'FIRST');

    const { id } = await dispatch({ method: 'POST', path: '/api/documents', body: {
      doc_type: 'quotation', doc_number: 'E2E-CTL-D', customer_name: 'C', doc_date: '2026-01-01',
    } });
    // First (and only) set on a fresh doc → oldPathToDelete null → no safeDeleteAttachment.
    await dispatch({ method: 'PUT', path: `/api/documents/${id}/tax-invoice`, body: { tax_invoice_attachment_path: firstRel } });
    const doc = await dispatch({ method: 'GET', path: `/api/documents/${id}`, body: null });

    return {
      firstFileExists: fs.existsSync(firstAbs),
      bystanderExists: fs.existsSync(bystanderAbs),
      storedPath: doc.tax_invoice_attachment_path,
    };
  }, { root: PROJECT_ROOT });

  expect(r.firstFileExists).toBe(true);           // the just-set file is not deleted
  expect(r.bystanderExists).toBe(true);           // unrelated file is not deleted
  expect(r.storedPath).toBe('attachments/docs/first-control-d.pdf');
});
