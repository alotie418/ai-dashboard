#!/usr/bin/env node
// PROPOSAL (P2-0 v4) — not committed. Closed-set guard over the report subsystem's public
// API, driven by the Swift symbol graph rather than by scanning source text.
//
// WHY THE SYMBOL GRAPH: a regex over `public ` misses members added by an extension in
// another file, multi-line declarations, attributed declarations, subscripts, and
// compiler-derived members. The graph is produced by the compiler, so it sees all of them.
//
// WHY THE UNION FILTER: filtering only on `location.uri` containing "/Reports/" is
// bypassable — `public extension PresentedReport { var rawPayload: Double { 0 } }` declared
// anywhere else in the module attaches a public member to a closed-set type while its
// location points outside Reports/. Measured and pinned by counterexample. A symbol is in
// scope when EITHER holds:
//     (a) it is declared under Sources/SoloLedgerCore/Reports/, OR
//     (b) the ROOT of its pathComponents is one of the closed-set type names.
//
// HYGIENE: the build and the symbol graph go to mkdtemp under the SYSTEM temp dir with
// their own --scratch-path, removed in a finally. Nothing is written inside the repository.
//
//   NOTE, and it is the reason this file has no `process.exit()` inside the work function:
//   `process.exit()` terminates immediately and SKIPS `finally`. An earlier draft leaked one
//   temp directory per FAILING run — measured: a passing run left the count unchanged, a
//   failing run incremented it. Every path here returns a code and lets `finally` run.
//
// FAIL CLOSED: build failure, missing graph, malformed JSON, an empty symbol list, a missing
// or malformed allowlist, and any public symbol without a location that is not a recognised
// compiler-derived member all return non-zero.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PKG = process.env.SL_PKG_PATH ?? join(ROOT, 'native/SoloLedger');
const ALLOWLIST_PATH = join(ROOT, 'scripts/reports-public-surface.allowlist.json');
const PRINT_MODE = process.argv.includes('--print');

// ── The closed set ────────────────────────────────────────────────────────────────
// Root type names whose ENTIRE public surface is governed here, wherever declared.
const CLOSED_ROOTS = new Set([
  'ReportBuilder', 'ReportOutcome', 'ReportBlocker', 'ReportPeriod',
  'PresentedReport', 'PresentedSection', 'PresentedLine', 'ReportLineUnit',
  'PresentedNote', 'PresentedMonth', 'PresentedCashflow', 'PresentedCashflowSection',
  'PresentedWarning', 'PresentedTaxInclusiveSummary',
  'PresentedParameter', 'ReportParameterKey', 'StoredSettingState',
  'ParameterEffect', 'EffectOrigin', 'ParameterConsumption',
  'ReportFieldPresentation', 'ReportRateProvenance',
  'ReportSectionPresentation', 'ReportTypePresentation',
  'ReportRateParameter', 'ReportSource',
]);

// Compiler-DERIVED members carry no `location`. They cannot introduce data of their own —
// they are determined by the type's stored properties and its declared conformances — so
// they are accepted by RULE rather than enumerated, which keeps the allowlist from churning
// whenever a presented type gains `Equatable`. Anything else without a location FAILS.
const DERIVED_LEAF = new Set(['init(rawValue:)', 'rawValue', 'hashValue', 'hash(into:)']);
const isDerived = (s) =>
  s.identifier?.precise?.includes('::SYNTHESIZED::') ||
  DERIVED_LEAF.has(s.pathComponents[s.pathComponents.length - 1]);

function run() {
  const work = mkdtempSync(join(tmpdir(), 'sl-symgraph-'));
  try {
    const graphDir = join(work, 'graph');
    try {
      execFileSync('swift', [
        'build', '--package-path', PKG, '--scratch-path', join(work, 'build'),
        '-Xswiftc', '-emit-symbol-graph',
        '-Xswiftc', '-emit-symbol-graph-dir', '-Xswiftc', graphDir,
      ], { stdio: 'pipe', env: process.env });
    } catch (e) {
      console.error('✗ swift build (symbol graph) failed — the guard cannot verify anything.');
      console.error(String(e.stderr ?? e).slice(-2000));
      return 1;
    }

    const graphFile = join(graphDir, 'SoloLedgerCore.symbols.json');
    if (!existsSync(graphFile)) {
      console.error(`✗ symbol graph missing at ${graphFile}. Present: ${
        existsSync(graphDir) ? readdirSync(graphDir).join(', ') : '(no dir)'}`);
      return 1;
    }
    let graph;
    try { graph = JSON.parse(readFileSync(graphFile, 'utf8')); }
    catch (e) { console.error(`✗ symbol graph is not valid JSON: ${e.message}`); return 1; }
    if (!Array.isArray(graph.symbols) || graph.symbols.length === 0) {
      console.error('✗ symbol graph carries no symbols — refusing to pass vacuously.');
      return 1;
    }

    // ── Collect the in-scope public surface ───────────────────────────────────────
    const found = new Map();                    // "kind\tpath" -> declaring file
    let derived = 0, unlocated = 0;
    for (const s of graph.symbols) {
      if (s.accessLevel !== 'public' && s.accessLevel !== 'open') continue;
      const path = s.pathComponents.join('/');
      const uri = s.location?.uri ?? '';
      const inReports = uri.includes('/Sources/SoloLedgerCore/Reports/');
      const rootClosed = CLOSED_ROOTS.has(s.pathComponents[0]);
      if (!inReports && !rootClosed) continue;                       // ← UNION filter
      if (!s.location) {
        if (isDerived(s)) { derived++; continue; }
        console.error(`✗ ${path} [${s.kind.displayName}] is public, has no source location, `
          + 'and is not a recognised compiler-derived member.');
        unlocated++;
        continue;
      }
      found.set(`${s.kind.displayName}\t${path}`,
                uri.split('/Sources/SoloLedgerCore/')[1] ?? uri);
    }

    if (PRINT_MODE) {
      if (unlocated) return 1;                  // never emit an allowlist from a failing scan
      console.log(JSON.stringify([...found.keys()].sort(), null, 2));
      return 0;
    }

    let allowlist;
    try {
      const list = JSON.parse(readFileSync(ALLOWLIST_PATH, 'utf8'));
      if (!Array.isArray(list)) throw new Error('not a JSON array');
      allowlist = new Set(list);
    } catch (e) {
      console.error(`✗ allowlist unusable at ${ALLOWLIST_PATH}: ${e.message}`);
      return 1;
    }

    const added = [...found.keys()].filter((k) => !allowlist.has(k)).sort();
    const stale = [...allowlist].filter((k) => !found.has(k)).sort();

    console.log('=== Reports public-surface guard (symbol graph, closed set) ===\n');
    console.log(`Scope: declared under Reports/ OR rooted in one of ${CLOSED_ROOTS.size} closed-set types`);
    console.log(`Authored public symbols in scope: ${found.size} (+${derived} compiler-derived)`);
    console.log(`Allowlist entries: ${allowlist.size}\n`);

    for (const k of added) {
      const [kind, path] = k.split('\t');
      console.error(`  ✗ UNDECLARED public symbol: ${path}  [${kind}]  declared in ${found.get(k)}`);
    }
    for (const k of stale) {
      const [kind, path] = k.split('\t');
      console.error(`  ✗ STALE allowlist entry (no longer public): ${path}  [${kind}]`);
    }
    if (added.length || stale.length || unlocated) {
      console.error('\n❌ The App-facing report surface is a CLOSED SET. A new public symbol here '
        + 'is reachable from the SwiftUI target and can hand it an unclassified value. Either keep '
        + 'it internal, or add it to scripts/reports-public-surface.allowlist.json in the same PR '
        + 'that justifies it. Regenerate: node scripts/check-reports-public-surface.mjs --print');
      return 1;
    }
    console.log('✓ public report surface matches the declared closed set exactly.');
    return 0;
  } finally {
    rmSync(work, { recursive: true, force: true });   // runs on EVERY path — no process.exit above
  }
}

process.exitCode = run();
