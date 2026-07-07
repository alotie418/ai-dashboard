// Real-Electron e2e — backup/restore IPC closed loop (P1-4).
//
// Covers the two ipcMain.handle closures whose ORCHESTRATION had zero test coverage
// (the pure fs helpers are unit-tested in scripts/test-backup-bundle.mjs and
// scripts/test-auto-backup.mjs, but the handler-level step ordering — validate →
// pre-restore auto-backup → closeDb → atomic replace → wal/shm cleanup → attachment
// merge — only exists inside electron/handlers/index.js):
//   • app:exportDb — wal checkpoint → dialog.showSaveDialog → writeExportBundle
//   • app:importDb — pick → resolve → header/quick_check/tables/version probe →
//                    auto-backup current DB → closeDb → copy+rename → rm -wal/-shm →
//                    mergeAttachments (add-only) → caller relaunches
//
// Gap map (see engineering-audit P1-4): G1 export loop · G2 import loop · G3 restored
// data readable · G4 attachment refs survive · G5 failures abort and keep the old DB ·
// G6 pre-restore safety net exists · G7 stale -wal/-shm removed · G8 startup autoBackup
// wiring runs in the real main process (asserted after the post-import lazy reconnect).
//
// Deliberately NOT covered (documented decision, not an oversight):
//   • Disk-full / read-only-fs error paths (AUTOBACKUP_FAILED / REPLACE_FAILED):
//     needs fs monkeypatching inside the main process — high complexity, low signal;
//     diskErrorCode mapping is unit-tested in scripts/test-db-errors.mjs.
//   • Orphan-attachment GC / backups-dir size reporting: the features do not exist
//     (audit item P2-3), so there is nothing to test.
//
// Tests in this file are ORDER-DEPENDENT (one Electron launch, one shared DB):
//   T1 creates sale-1 + attachment A and exports bundle-1 (DB snapshot = 1 sale).
//   T3 adds sale-2 + attachment B, then restores bundle-1 → DB back to 1 sale,
//      attachments A and B both present (merge is add-only).
//   T4–T7 each attempt a failing/cancelled import and assert the DB still holds
//      exactly the 1 post-restore sale (old data never lost on a refused import).

import { test, expect } from '@playwright/test';
import type { ElectronApplication, Page } from '@playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { launchApp, disposeApp, waitForReady, PROJECT_ROOT, type LaunchedApp } from './helpers/launch';
import {
  openPreloadPage, invokeViaPage, stubOpenDialog, stubSaveDialog,
  dispatchInMain, seedAttachment, attachmentExists,
} from './helpers/ipc';

let app: LaunchedApp | undefined;
let electronApp: ElectronApplication;
let page: Page;

// Runtime-generated fixtures (bundle destinations, bogus import sources) — temp dir,
// separate from the isolated userData; never committed.
let srcDir: string;
let bundle1: string;

const exportDb = () => invokeViaPage<{ ok: boolean; path?: string; attachments?: number; error?: string }>(page, 'app:exportDb');
const importDb = () => invokeViaPage<{ ok: boolean; error?: string; autoBackupPath?: string; attachmentsMerged?: number; restoredFrom?: string }>(page, 'app:importDb');
const listSales = () => invokeViaPage<any[]>(page, 'api:request', { method: 'GET', path: '/api/sales' });

// ── main-process fs/db probes (same createRequire idiom as helpers/ipc.ts) ──

/** { dbPath, dataDir } of the REAL isolated userData the main process runs on. */
function mainPaths(): Promise<{ dbPath: string; dataDir: string }> {
  return electronApp.evaluate((_e, { root }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const db = r(root + '/electron/db/index.js');
    return { dbPath: db.getDbPath(), dataDir: db.getDataDir() };
  }, { root: PROJECT_ROOT });
}

/** Row count of `sales` in an arbitrary db FILE (read-only open; independent handle). */
function countSalesInDbFile(p: string): Promise<number> {
  return electronApp.evaluate((_e, { root, file }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const Database = r('better-sqlite3');
    const d = new Database(file, { readonly: true, fileMustExist: true });
    try { return d.prepare('SELECT COUNT(*) AS c FROM sales').get().c as number; } finally { d.close(); }
  }, { root: PROJECT_ROOT, file: p });
}

/** fs.existsSync in the main process (userData paths live on the same machine, but
 *  going through main keeps every probe on one realm and one fs view). */
function existsInMain(p: string): Promise<boolean> {
  return electronApp.evaluate((_e, { root, file }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    return r('node:fs').existsSync(file);
  }, { root: PROJECT_ROOT, file: p });
}

/** Write a file (mkdir -p parent) in the main process. */
function writeInMain(p: string, data: string): Promise<void> {
  return electronApp.evaluate((_e, { root, file, body }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const nfs = r('node:fs');
    nfs.mkdirSync(r('node:path').dirname(file), { recursive: true });
    nfs.writeFileSync(file, body);
  }, { root: PROJECT_ROOT, file: p, body: data });
}

/** Checkpoint the LIVE connection so committed rows reach the main db file. */
function checkpointLiveDb(): Promise<void> {
  return electronApp.evaluate((_e, { root }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    r(root + '/electron/db/index.js').getDb().pragma('wal_checkpoint(TRUNCATE)');
  }, { root: PROJECT_ROOT });
}

/** Create a standalone SQLite file: optional bare core tables + user_version. */
function makeSqliteFile(p: string, opts: { withCoreTables: boolean; userVersion: number }): Promise<void> {
  return electronApp.evaluate((_e, { root, file, withCoreTables, userVersion }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const Database = r('better-sqlite3');
    const d = new Database(file);
    if (withCoreTables) {
      d.exec('CREATE TABLE products (id TEXT PRIMARY KEY); CREATE TABLE transactions (id TEXT PRIMARY KEY);');
    } else {
      d.exec('CREATE TABLE misc (id TEXT PRIMARY KEY);');
    }
    d.pragma(`user_version = ${userVersion}`);
    d.close();
  }, { root: PROJECT_ROOT, file: p, ...opts });
}

/** Names of auto-* snapshot dirs currently in <dataDir>/backups ([] if none). */
function listAutoSnapshotDirs(dataDir: string): Promise<string[]> {
  return electronApp.evaluate((_e, { root, dir }) => {
    const r = (process as any).getBuiltinModule('module').createRequire(root + '/electron/main.js');
    const nfs = r('node:fs');
    const p = r('node:path').join(dir, 'backups');
    try {
      return nfs.readdirSync(p, { withFileTypes: true })
        .filter((e: any) => e.isDirectory() && e.name.startsWith('auto-'))
        .map((e: any) => e.name);
    } catch { return []; }
  }, { root: PROJECT_ROOT, dir: dataDir });
}

test.beforeAll(async () => {
  app = await launchApp();
  electronApp = app.electronApp;
  await waitForReady(app);
  page = await openPreloadPage(electronApp);

  srcDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sololedger-e2e-backup-'));
  bundle1 = path.join(srcDir, 'bundle-1');
});

test.afterAll(async () => {
  await disposeApp(app);
  try { fs.rmSync(srcDir, { recursive: true, force: true }); } catch { /* best-effort */ }
});

test('smoke: preload page reaches the real api:request bridge', async () => {
  const settings = await invokeViaPage<any>(page, 'api:request', { method: 'GET', path: '/api/settings' });
  expect(settings.accounting_locale).toBe('CN');
});

// ───────────────────────── app:exportDb ─────────────────────────

test('T1/G1 export happy: bundle carries db (incl. WAL-fresh row) + attachments', async () => {
  await dispatchInMain(electronApp, {
    method: 'POST', path: '/api/sales',
    body: { id: 'e2e-sale-1', date: '2026-06-01', customer: 'E2E-Cust-1', tons: 2, totalAmount: 200 },
  });
  await seedAttachment(electronApp, 'doc-e2e-a.pdf', 'PDF-A');
  // NO manual checkpoint here: the fresh row may still live only in the -wal.
  // app:exportDb itself must checkpoint before copying — that is the G1 assertion.
  await stubSaveDialog(electronApp, { canceled: false, filePath: bundle1 });

  const r = await exportDb();
  expect(r.ok).toBe(true);
  expect(r.path).toBe(bundle1);
  expect(r.attachments).toBe(1);
  expect(fs.existsSync(path.join(bundle1, 'sololedger.db'))).toBe(true);
  expect(fs.readFileSync(path.join(bundle1, 'attachments', 'docs', 'doc-e2e-a.pdf'), 'utf8')).toBe('PDF-A');
  // The exported COPY must already contain the row written just before export.
  expect(await countSalesInDbFile(path.join(bundle1, 'sololedger.db'))).toBe(1);
});

test('T2 export cancel: ok:false and no bundle is produced', async () => {
  const bundle2 = path.join(srcDir, 'bundle-2');
  await stubSaveDialog(electronApp, { canceled: true });
  const r = await exportDb();
  expect(r.ok).toBe(false);
  expect(fs.existsSync(bundle2)).toBe(false);
});

// ───────────────────────── app:importDb ─────────────────────────

test('T3/G2+G3+G4+G6+G7+G8 import happy round-trip: bundle restores the export-time state', async () => {
  const { dbPath, dataDir } = await mainPaths();

  // Diverge from the exported snapshot: a second sale + a second attachment.
  await dispatchInMain(electronApp, {
    method: 'POST', path: '/api/sales',
    body: { id: 'e2e-sale-2', date: '2026-06-02', customer: 'E2E-Cust-2', tons: 1, totalAmount: 100 },
  });
  await seedAttachment(electronApp, 'doc-e2e-b.pdf', 'PDF-B');
  // Checkpoint NOW so both sales reach the main db file — the pre-restore safety net
  // (a plain copyFileSync of the main file) must capture the 2-sale state, and the
  // garbage -wal written next must not cost us any committed row.
  await checkpointLiveDb();
  expect((await listSales()).length).toBe(2);

  // Stale sidecar files: importDb must remove them after the atomic replace, or the
  // restored db would be corrupted by a leftover WAL from the OLD database (G7).
  await writeInMain(`${dbPath}-wal`, 'garbage-wal');
  await writeInMain(`${dbPath}-shm`, 'garbage-shm');

  await stubOpenDialog(electronApp, { canceled: false, filePaths: [bundle1] });
  const r = await importDb();

  expect(r.ok).toBe(true);
  expect(r.restoredFrom).toBe(bundle1);
  // G6 — pre-restore safety net: flat autobackup file exists and holds the 2-sale state.
  expect(r.autoBackupPath).toBeTruthy();
  expect(path.basename(r.autoBackupPath!).startsWith('sololedger-autobackup-before-restore-')).toBe(true);
  expect(await existsInMain(r.autoBackupPath!)).toBe(true);
  expect(await countSalesInDbFile(r.autoBackupPath!)).toBe(2);
  // G7 — stale -wal/-shm of the OLD database are gone.
  expect(await existsInMain(`${dbPath}-wal`)).toBe(false);
  expect(await existsInMain(`${dbPath}-shm`)).toBe(false);
  // G4 — bundle attachment merged in; post-export attachment untouched (add-only merge).
  expect(r.attachmentsMerged).toBe(1);
  expect(await attachmentExists(electronApp, 'attachments/docs/doc-e2e-a.pdf')).toBe(true);
  expect(await attachmentExists(electronApp, 'attachments/docs/doc-e2e-b.pdf')).toBe(true);

  // G2+G3 — first api:request after importDb lazily reconnects (closeDb set db=null;
  // getDb() re-runs initDatabase on the RESTORED file — the same path a real relaunch
  // takes) and must read exactly the export-time state.
  const sales = await listSales();
  expect(sales.length).toBe(1);
  expect(sales[0].id).toBe('e2e-sale-1');
  expect(sales[0].customer).toBe('E2E-Cust-1');

  // G8 — the reconnect ran the REAL initDatabase, whose startup auto-backup must have
  // produced an auto-* snapshot dir (launch itself started with no db → was skipped).
  expect((await listAutoSnapshotDirs(dataDir)).length).toBeGreaterThanOrEqual(1);
});

test('T4 import cancel: ok:false, current db untouched', async () => {
  await stubOpenDialog(electronApp, { canceled: true, filePaths: [] });
  const r = await importDb();
  expect(r.ok).toBe(false);
  expect((await listSales()).length).toBe(1);
});

test('T5/G5 import of a non-SQLite file: INVALID_FILE, old data still readable', async () => {
  const notDb = path.join(srcDir, 'not-a-db.db');
  fs.writeFileSync(notDb, 'this is definitely not a sqlite database');
  await stubOpenDialog(electronApp, { canceled: false, filePaths: [notDb] });
  const r = await importDb();
  expect(r.ok).toBe(false);
  expect(r.error).toBe('INVALID_FILE');
  const sales = await listSales();
  expect(sales.length).toBe(1);
  expect(sales[0].id).toBe('e2e-sale-1');
});

test('T6/G5 import of a valid SQLite missing core tables: INVALID_FILE, old db kept', async () => {
  const noTables = path.join(srcDir, 'no-core-tables.db');
  await makeSqliteFile(noTables, { withCoreTables: false, userVersion: 1 });
  await stubOpenDialog(electronApp, { canceled: false, filePaths: [noTables] });
  const r = await importDb();
  expect(r.ok).toBe(false);
  expect(r.error).toBe('INVALID_FILE');
  expect((await listSales()).length).toBe(1);
});

test('T7/G5 import of a future-schema db: NEWER_VERSION, old db kept', async () => {
  const future = path.join(srcDir, 'future-schema.db');
  await makeSqliteFile(future, { withCoreTables: true, userVersion: 999 });
  await stubOpenDialog(electronApp, { canceled: false, filePaths: [future] });
  const r = await importDb();
  expect(r.ok).toBe(false);
  expect(r.error).toBe('NEWER_VERSION');
  const sales = await listSales();
  expect(sales.length).toBe(1);
  expect(sales[0].id).toBe('e2e-sale-1');
});
