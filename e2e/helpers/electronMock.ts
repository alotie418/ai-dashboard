// IPC-boot helper for the locale-matrix e2e suite (Phase 3 migration).
//
// Injects a mock `window.electronAPI` BEFORE the app boots so the SPA — served by
// `vite preview` in a plain Chromium tab — takes the desktop IPC path instead of
// the legacy Web `fetch()` path. With electronAPI present, `isElectron()` is true:
// App.tsx skips the Web auth gate (no /auth/check) and resolves onboarding via
// `providers:hasAny`; services/api.ts routes every request through
// `electronAPI.invoke('api:request', { method, path, body })`.
//
// The mock surface mirrors the REAL preload (electron/preload.js): exactly
// `{ invoke, platform, isElectron }` — no `buildTarget` (removed from preload).
//
// `api:request` routing intentionally mirrors bootCombo's page.route('**/api/**')
// branch (settings / dashboard / list-endpoints → [] / catch-all → {}), so the
// rendered DOM is identical to the Web-boot path. Per-test extras are passed as
// DATA so the injected function stays fully serializable (no Node closures):
//   • apiResponses — ordered [{ match, method?, bodyMatch?, json?, reject? }] checked
//     BEFORE settings/dashboard/lists. `match` is a regex tested against the path
//     (query stripped); method/bodyMatch narrow it; `reject` makes invoke reject
//     (mirrors an HTTP error → api.ts throws). Handles body-dependent responses
//     (e.g. recategorize dryRun) and method-aware routes (conversations CRUD).
//   • appChannels — map of non-api channel → resolved value (app:exportReportPdf, …).
//   • recordCalls — record every invoke as { channel, method, path, body } to
//     window.__calls, read back in-test via page.evaluate (replaces the legacy
//     Node-side page.route call recording).

import type { Page } from '@playwright/test';
import { SETTINGS, DASHBOARD } from './fixtures';

export type ApiResponse = {
  /** Regex string tested against the (query-stripped) request path. */
  match: string;
  /** Optional HTTP method narrowing (GET/POST/PUT/DELETE). */
  method?: string;
  /** Optional partial body match — every key must strict-equal the request body. */
  bodyMatch?: Record<string, any>;
  /** Resolved value when matched. */
  json?: any;
  /** When set, invoke REJECTS with this message instead of resolving (mirrors HTTP error). */
  reject?: string;
};

export type ElectronMockOpts = {
  /** Accounting locale → default SETTINGS(acc)/DASHBOARD(acc). Defaults to 'CN'. */
  acc?: string;
  /** Override the /api/settings response (defaults to SETTINGS(acc)). */
  settings?: any;
  /** Override the /api/dashboard response (defaults to DASHBOARD(acc)). */
  dashboard?: any;
  /** providers:hasAny — must be true so the desktop boot skips the BYOK onboarding wizard. */
  hasProvider?: boolean;
  /** providers:list response. Defaults to []. */
  providers?: any[];
  /** Extra api:request responses (see ApiResponse), matched BEFORE settings/dashboard/lists. */
  apiResponses?: ApiResponse[];
  /** Non-api channels (e.g. 'app:exportReportPdf') → resolved value. */
  appChannels?: Record<string, any>;
  /** Record every invoke to window.__calls for in-test assertions via page.evaluate. */
  recordCalls?: boolean;
};

/** Inject the mock window.electronAPI. Call BEFORE navigation (addInitScript runs pre-boot). */
export async function installElectronMock(page: Page, opts: ElectronMockOpts = {}): Promise<void> {
  const acc = opts.acc ?? 'CN';
  await page.addInitScript((data: any) => {
    const lists = /\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|documents|reports\/types)/;
    if (data.recordCalls) (window as any).__calls = (window as any).__calls || [];
    const record = (channel: string, payload: any) => {
      if (!data.recordCalls) return;
      (window as any).__calls.push({
        channel,
        method: payload && payload.method,
        path: payload && payload.path,
        body: payload && payload.body,
      });
    };
    (window as any).electronAPI = {
      isElectron: true,
      platform: 'darwin',
      invoke: (channel: string, payload: any) => {
        record(channel, payload);
        if (channel === 'providers:hasAny') return Promise.resolve(data.hasProvider);
        if (channel === 'providers:list') return Promise.resolve(data.providers);
        if (channel === 'api:request') {
          const p = (payload && payload.path) || '';
          const cleanPath = p.split('?')[0];
          const method = (payload && payload.method) || 'GET';
          const body = (payload && payload.body) || {};
          for (const r of data.apiResponses) {
            if (!new RegExp(r.match).test(cleanPath)) continue;
            if (r.method && r.method !== method) continue;
            if (r.bodyMatch && !Object.keys(r.bodyMatch).every((k) => body[k] === r.bodyMatch[k])) continue;
            if (r.reject !== undefined) return Promise.reject(new Error(r.reject));
            return Promise.resolve(r.json);
          }
          if (p.includes('/api/settings')) return Promise.resolve(data.settings);
          if (p.includes('/api/dashboard')) return Promise.resolve(data.dashboard);
          if (lists.test(p)) return Promise.resolve([]);
          return Promise.resolve({});
        }
        if (Object.prototype.hasOwnProperty.call(data.appChannels, channel)) {
          return Promise.resolve(data.appChannels[channel]);
        }
        return Promise.resolve({});
      },
    };
  }, {
    settings: opts.settings ?? SETTINGS(acc),
    dashboard: opts.dashboard ?? DASHBOARD(acc),
    hasProvider: opts.hasProvider ?? true,
    providers: opts.providers ?? [],
    apiResponses: opts.apiResponses ?? [],
    appChannels: opts.appChannels ?? {},
    recordCalls: opts.recordCalls ?? false,
  });
}

/** Set the UI language, navigate, and wait for the sidebar <nav>. Assumes electronAPI
 *  is already injected (by installElectronMock or a test's own inline mock). */
export async function gotoApp(page: Page, ui: string): Promise<void> {
  await page.addInitScript((l) => { try { localStorage.setItem('sololedger-lang', l as string); } catch { /* ignore */ } }, ui);
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('nav', { timeout: 20_000 });
}

/** IPC-boot equivalent of bootCombo(): inject the mock electronAPI, then navigate. */
export async function bootComboIPC(page: Page, ui: string, acc: string, opts: ElectronMockOpts = {}): Promise<void> {
  await installElectronMock(page, { acc, ...opts });
  await gotoApp(page, ui);
}
