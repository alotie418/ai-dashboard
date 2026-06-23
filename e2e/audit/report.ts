// Report model + writers for the UI-audit smoke harness (phase 1).
//
// One audit run = one timestamped directory under artifacts/ui-audit/<ts>/ holding:
//   • report.md            — human-readable findings, grouped by severity
//   • summary.json         — machine-readable summary (counts + merge advice + findings)
//   • <locale>/<page>.png  — full-page screenshot per (locale, page)
//   • <locale>/<page>__<modal>.png — screenshot per opened modal
//
// artifacts/ is gitignored: a run produces local evidence, never committed source.

import * as fs from 'node:fs';
import * as path from 'node:path';

export type Severity = 'P0' | 'P1' | 'P2' | 'P3';
export type MergeAdvice = 'PASS' | 'REVIEW' | 'BLOCK';

export type Finding = {
  severity: Severity;
  locale: string;            // UI language (en/ja/ko/fr/...)
  accountingLocale: string;  // accounting regime (US/CN/...)
  page: string;              // dashboard/purchase/sales/finance/settings
  modal?: string;            // add-purchase / add-sale / ai-widget (when applicable)
  type: string;              // rule id, e.g. 'raw-i18n-key'
  message: string;
  snippet?: string;          // offending text context
  selector?: string;         // DOM selector / locator hint
  screenshot?: string;       // path relative to AUDIT_DIR
  sourceFileGuess?: string;
  possibleFalsePositive?: boolean;
};

export type AuditScope = {
  uiLanguages: string[];
  accountingLocales: string[];
  pages: string[];
  modals: string[];
};

export type AuditCounters = {
  pagesScanned: number;  // total (combo × page) visits
  combos: number;        // (ui × acc) booted
  modals: number;        // total modal/widget interactions checked
};

export type AuditSummary = {
  timestamp: string;
  mode: string;
  scope: AuditScope;
  counts: {
    pagesScanned: number;
    combos: number;
    modals: number;
    findings: number;
    P0: number;
    P1: number;
    P2: number;
    P3: number;
    hardFail: number;
  };
  mergeAdvice: MergeAdvice;
  knownLimitations: string[];
  findings: Finding[];
};

// One run dir, computed once at module load. The audit config runs workers:1, so a
// single process imports this module once → a single stable timestamp/dir for the run.
// Millisecond resolution ('2026-06-23_15-20-01-408') keeps run dirs unique even for
// two runs started in the same second, and stays lexicographically sortable so the
// wrapper's newest-dir pick is correct.
const TS = new Date()
  .toISOString()
  .replace('T', '_')
  .replace(/[:.]/g, '-')
  .slice(0, 23);
export const AUDIT_TIMESTAMP = TS;
export const AUDIT_DIR = path.join('artifacts', 'ui-audit', TS);

/** mkdir -p the run dir (or a per-locale sub-dir) and return its absolute-ish path. */
export function ensureAuditDir(sub?: string): string {
  const dir = sub ? path.join(AUDIT_DIR, sub) : AUDIT_DIR;
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

export const KNOWN_LIMITATIONS: string[] = [
  'Native <input type="date"> placeholder text and the pop-up calendar render in the OS / Chromium process locale, not the renderer <html lang>. That language is NOT in the DOM, so it is a known limitation — the audit only validates input[type=date].value format (empty or YYYY-MM-DD), never the placeholder/calendar language.',
  'ja Chinese-leak cannot be reliably auto-detected because Japanese itself uses kanji. Phase 1 does not judge ja text for Chinese leakage.',
  'English-residue and Chinese-leak heuristics (ja/ko/fr/en) are deferred to a phase-2 PR once the smoke framework is stable; only the specific US cross-regime tax-term check runs in phase 1.',
  'Automated audit cannot replace human judgement of translation naturalness, accounting-term accuracy, or tax-wording correctness.',
];

export function severityCounts(findings: Finding[]): Record<Severity, number> {
  const c: Record<Severity, number> = { P0: 0, P1: 0, P2: 0, P3: 0 };
  for (const f of findings) c[f.severity]++;
  return c;
}

/** A "hard fail" is a confident P0/P1 (modal button unreachable, raw key, overflow,
 *  K/M/万 money abbreviation, …). possibleFalsePositive findings never count as hard. */
export function isHardFail(f: Finding): boolean {
  return (f.severity === 'P0' || f.severity === 'P1') && !f.possibleFalsePositive;
}

export function mergeAdvice(findings: Finding[]): MergeAdvice {
  if (findings.some(isHardFail)) return 'BLOCK';
  if (findings.length > 0) return 'REVIEW';
  return 'PASS';
}

export function buildSummary(
  findings: Finding[],
  scope: AuditScope,
  mode: string,
  counters: AuditCounters,
): AuditSummary {
  const c = severityCounts(findings);
  return {
    timestamp: AUDIT_TIMESTAMP,
    mode,
    scope,
    counts: {
      pagesScanned: counters.pagesScanned,
      combos: counters.combos,
      modals: counters.modals,
      findings: findings.length,
      P0: c.P0,
      P1: c.P1,
      P2: c.P2,
      P3: c.P3,
      hardFail: findings.filter(isHardFail).length,
    },
    mergeAdvice: mergeAdvice(findings),
    knownLimitations: KNOWN_LIMITATIONS,
    findings,
  };
}

function findingLine(f: Finding): string {
  const where = `[locale=${f.locale} acc=${f.accountingLocale}] page=${f.page}${f.modal ? ` modal=${f.modal}` : ''}`;
  const lines = [`- **${where}** — \`${f.type}\`: ${f.message}`];
  if (f.snippet) lines.push(`  - snippet: \`${f.snippet.replace(/`/g, "'").slice(0, 200)}\``);
  if (f.selector) lines.push(`  - selector: \`${f.selector}\``);
  if (f.screenshot) lines.push(`  - screenshot: \`${f.screenshot}\``);
  if (f.sourceFileGuess) lines.push(`  - sourceFileGuess: ${f.sourceFileGuess}`);
  lines.push(`  - possibleFalsePositive: ${f.possibleFalsePositive ? 'true' : 'false'}`);
  return lines.join('\n');
}

function renderReportMd(summary: AuditSummary): string {
  const { counts, scope } = summary;
  const out: string[] = [];
  out.push(`# UI Audit (${summary.mode}) — ${summary.timestamp}`);
  out.push('');
  out.push(`**Merge advice: ${summary.mergeAdvice}**  (PASS = no findings · REVIEW = only P2/P3 · BLOCK = any confident P0/P1)`);
  out.push('');
  out.push('> This is an automated UI smoke audit. It establishes a reusable framework and reliable hard checks.');
  out.push('> It does NOT replace human judgement of translation naturalness, accounting-term accuracy, or tax wording.');
  out.push('> Findings below are recorded for triage only — they are not fixed by the audit run.');
  out.push('');
  out.push('## Scope');
  out.push(`- UI languages: ${scope.uiLanguages.join(', ')}`);
  out.push(`- Accounting locales: ${scope.accountingLocales.join(', ')}`);
  out.push(`- Pages: ${scope.pages.join(', ')}`);
  out.push(`- Modals: ${scope.modals.join(', ')}`);
  out.push('');
  out.push('## Summary');
  out.push('| metric | value |');
  out.push('| --- | --- |');
  out.push(`| Pages scanned | ${counts.pagesScanned} |`);
  out.push(`| Combos (ui×acc) | ${counts.combos} |`);
  out.push(`| Modals checked | ${counts.modals} |`);
  out.push(`| Findings total | ${counts.findings} |`);
  out.push(`| P0 | ${counts.P0} |`);
  out.push(`| P1 | ${counts.P1} |`);
  out.push(`| P2 | ${counts.P2} |`);
  out.push(`| P3 | ${counts.P3} |`);
  out.push(`| Hard fail | ${counts.hardFail} |`);
  out.push(`| Merge advice | ${summary.mergeAdvice} |`);
  out.push('');
  out.push('## Findings');
  if (summary.findings.length === 0) {
    out.push('');
    out.push('_No findings._');
  } else {
    for (const sev of ['P0', 'P1', 'P2', 'P3'] as Severity[]) {
      const group = summary.findings.filter((f) => f.severity === sev);
      out.push('');
      out.push(`### ${sev} (${group.length})`);
      if (group.length === 0) {
        out.push('_none_');
        continue;
      }
      for (const f of group) out.push(findingLine(f));
    }
  }
  out.push('');
  out.push('## Known limitations');
  for (const k of summary.knownLimitations) out.push(`- ${k}`);
  out.push('');
  return out.join('\n');
}

export function writeReport(summary: AuditSummary): { reportPath: string; summaryPath: string } {
  ensureAuditDir();
  const reportPath = path.join(AUDIT_DIR, 'report.md');
  const summaryPath = path.join(AUDIT_DIR, 'summary.json');
  fs.writeFileSync(reportPath, renderReportMd(summary), 'utf8');
  fs.writeFileSync(summaryPath, JSON.stringify(summary, null, 2), 'utf8');
  return { reportPath, summaryPath };
}
