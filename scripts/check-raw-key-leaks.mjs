#!/usr/bin/env node
// Raw i18n key leak scanner.
//
// Heuristic: find places in component source where an i18n-namespaced
// string is used as the literal display value, NOT through t() / a helper.
// Catches patterns like:
//   <div>tableHeaders.taxAmount</div>
//   `${someVar} sales.formOptional`
//   "Hello finance.balance"
//
// Does NOT flag legitimate usage inside locale JSON files, t() calls,
// object property access, route paths, or imports.

import { readdir, readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

// Scan these directories
const SCAN_DIRS = ['components', 'services', 'electron'];

// File extensions to scan
const EXTS = ['.ts', '.tsx', '.js'];

// i18n namespaces that should always go through t()
const I18N_NAMESPACES = [
  'tableHeaders', 'finance', 'sales', 'purchases', 'invoice', 'invoices',
  'dashboard', 'analysis', 'chat', 'common', 'common2', 'voice', 'ai',
  'transactions', 'usTax', 'accounts', 'settings', 'header', 'nav',
  'onboarding', 'alerts', 'aiInsights', 'charts',
];

// Build the leak pattern. We look for a string literal that contains
// `namespace.identifier` where namespace is in our list and identifier
// is camelCase or snake_case.
const namespaceAlt = I18N_NAMESPACES.join('|');
// Match string literals (single, double, backtick) containing the suspect token
const LEAK_PATTERN = new RegExp(
  `(['"\`])([^'"\`]*?)\\b(${namespaceAlt})\\.([a-zA-Z][a-zA-Z0-9_]*)([^'"\`]*?)\\1`,
  'g',
);

// Lines/snippets where the pattern is OK (whitelist)
function isAllowedContext(line, fullMatch, ns, key) {
  // Inside t('...') or t("...") call
  if (/\bt\s*\(\s*['"`][^'"`]*['"`]/.test(line)) return true;
  // labelKey: 'namespace.x' / promptKey: 'namespace.x' / nameKey: 'namespace.x'
  if (/\b(labelKey|promptKey|nameKey|key|systemPrompt|placeholderKey|i18nKey|labelI18nKey)\s*:/.test(line)) return true;
  // i18nMap-style mapping value: '\'someKey\': \'namespace.x\''
  if (/^\s*['"`][^'"`]*['"`]\s*:\s*['"`]\w+\.[\w]+['"`]/.test(line)) return true;
  // Const property value: someProp: 'namespace.key', (e.g. statusI18nMap entries)
  if (/^\s*[\w$]+\s*:\s*['"`]\w+\.[\w.]+['"`]/.test(line)) return true;
  // Import / require statements
  if (/^\s*(import|export|require\()/.test(line)) return true;
  // Comment line
  if (/^\s*\/\//.test(line) || /^\s*\*/.test(line)) return true;
  // Object literal that has lookup mapping (statusI18nMap etc.)
  if (/Map\s*[:=]|[Mm]ap\s*<[^>]*string/.test(line)) return true;
  // JSX expression: {someObject.property} — not an i18n key
  // The pattern matched a string literal, but if the line is using `{ident.subident}` JSX expression
  // without quotes, that's not a leak. (We're already only matching inside string literals,
  // but `{obj.prop}` inside a string template would match.)
  return false;
}

const PROBLEM_HARDCODES = [
  // Hardcoded inventory units in JSX
  { name: 'hardcoded 吨 in JSX', pattern: /['"`][^'"`]*吨[^'"`]*['"`]|>\s*吨\s*</g },
  { name: 'hardcoded 袋 in JSX', pattern: /['"`][^'"`]*袋[^'"`]*['"`]|>\s*袋\s*</g },
  { name: 'hardcoded ton unit suffix', pattern: /\$\{[^}]+\}t['"`]|\.toFixed\([^)]*\)\s*\+\s*['"`]t['"`]/g },
  // Currency symbols hardcoded in template literals or JSX text content
  // Catches things like `¥${val}` / `>¥{val}<` — money should go through formatMoney().
  { name: 'hardcoded ¥ currency', pattern: /`[^`]*¥\$\{[^}]+\}[^`]*`|>\s*¥\s*\{/g },
  { name: 'hardcoded € currency', pattern: /`[^`]*€\$\{[^}]+\}[^`]*`|>\s*€\s*\{/g },
  { name: 'hardcoded ₩ currency', pattern: /`[^`]*₩\$\{[^}]+\}[^`]*`|>\s*₩\s*\{/g },
  { name: 'hardcoded NT$ currency', pattern: /`[^`]*NT\$\$\{[^}]+\}[^`]*`|>\s*NT\$\s*\{/g },
];

const findings = [];

async function* walk(dir) {
  for (const ent of await readdir(dir, { withFileTypes: true })) {
    if (ent.name.startsWith('.') || ent.name === 'node_modules' || ent.name === 'dist') continue;
    const p = join(dir, ent.name);
    if (ent.isDirectory()) {
      yield* walk(p);
    } else if (EXTS.some(e => ent.name.endsWith(e))) {
      yield p;
    }
  }
}

async function scanFile(filepath) {
  const rel = relative(ROOT, filepath);
  const txt = await readFile(filepath, 'utf8');
  const lines = txt.split('\n');

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line || line.length === 0) continue;

    // ── Raw i18n key leaks ──
    LEAK_PATTERN.lastIndex = 0;
    let m;
    while ((m = LEAK_PATTERN.exec(line)) !== null) {
      const [full, _q, prefix, ns, key, suffix] = m;
      // Filter false positives:
      if (isAllowedContext(line, full, ns, key)) continue;
      if (new RegExp(`t\\s*\\(\\s*['"\`]${ns}\\.${key}['"\`]`).test(line)) continue;
      if (/Record<string|\[key:|i18n[A-Z]/.test(line)) continue;

      // Filter: leak token is inside ${...} interpolation
      // The match contains the whole quoted string; find the token offset inside.
      const tokenOffsetInMatch = full.indexOf(`${ns}.${key}`);
      const tokenAbsIdx = m.index + tokenOffsetInMatch;
      const beforeToken = line.slice(0, tokenAbsIdx);
      const dollarOpens = (beforeToken.match(/\$\{/g) || []).length;
      // count balanced } between ${ positions
      let nested = 0;
      for (let j = 0; j < beforeToken.length; j++) {
        if (beforeToken[j] === '$' && beforeToken[j+1] === '{') { nested++; j++; }
        else if (beforeToken[j] === '}' && nested > 0) { nested--; }
      }
      if (nested > 0) continue;

      // Filter: JSX text content surrounded by literal quote chars
      // e.g. "{analysis.summary}"  — the dot expression is inside JSX {...} interpolation
      // Pattern: the line contains a JSX brace right before the ns.key token
      const braceBefore = beforeToken.lastIndexOf('{');
      const beforeBrace = braceBefore >= 0 ? beforeToken.slice(0, braceBefore) : beforeToken;
      // If there's `{` and no corresponding `}` between brace and token, we're inside JSX expr
      if (braceBefore >= 0) {
        const between = beforeToken.slice(braceBefore + 1);
        if (!between.includes('}')) continue;
      }

      findings.push({
        file: rel,
        line: i + 1,
        type: 'raw-key-leak',
        token: `${ns}.${key}`,
        snippet: line.trim().slice(0, 120),
      });
    }

    // ── Hardcoded inventory unit suffixes ──
    // Skip helper files where unit labels are DEFINED (not consumed)
    const isUnitHelper = /(accountingHelpers|accountingLocaleConfig)\.(ts|js)$/.test(rel);
    if (!isUnitHelper) {
      for (const rule of PROBLEM_HARDCODES) {
        rule.pattern.lastIndex = 0;
        const m2 = rule.pattern.exec(line);
        if (m2) {
          // Skip CSV column alias data (e.g. tons: ['吨数', 'tons', ...])
          // These are header-matching patterns, not display labels.
          if (/^\s*\w+\s*:\s*\[/.test(line) && /['"`][^'"`]*['"`]\s*,/.test(line)) {
            continue;
          }
          findings.push({
            file: rel,
            line: i + 1,
            type: rule.name,
            token: m2[0],
            snippet: line.trim().slice(0, 120),
          });
        }
      }
    }
  }
}

// Cross-check: the invoice-query advanced-filter LABEL keys must resolve in
// every locale file. A reference to a key that is undefined in JSON renders
// the raw key in the UI (this is exactly how `invoices.clearAll` leaked — the
// t() call was correct but the key was missing from every locale file, so a
// pure source scan could never catch it).
//
// Scope note: this guards the advanced-filter LABELS only (the render items in
// the US invoice-query localization task). It deliberately does NOT guard the
// status-dropdown OPTION keys (statusVerified/statusCertified/...), the
// advancedFilterActive count line, or inputRecordCount/outputRecordCount — those
// are also missing in all locales but carry accountingLocale-vs-uiLanguage
// semantic decisions (CN-VAT 进项/销项/已认证 wording must differ from US), so
// they belong to a separate, deliberate localization pass.
const REQUIRED_INVOICE_LABEL_KEYS = [
  'advancedFilter', 'clearAll', 'dateRange', 'amountRange',
  'weightRange', 'statusFilter', 'allStatus', 'min', 'max',
];
async function checkInvoiceKeyResolution() {
  const langs = ['en', 'zh-CN', 'zh-TW', 'ja', 'ko', 'fr'];
  for (const lang of langs) {
    const txt = await readFile(join(ROOT, 'i18n/locales', `${lang}.json`), 'utf8');
    const dict = JSON.parse(txt).invoices || {};
    for (const key of REQUIRED_INVOICE_LABEL_KEYS) {
      const v = dict[key];
      if (v === undefined || (typeof v === 'string' && v.trim() === '')) {
        findings.push({
          file: `i18n/locales/${lang}.json`,
          line: 0,
          type: 'unresolved-i18n-key',
          token: `invoices.${key}`,
          snippet: `advanced-filter label missing/empty in ${lang}.json (would render raw key in UI)`,
        });
      }
    }
  }
}

async function main() {
  for (const dir of SCAN_DIRS) {
    const full = join(ROOT, dir);
    try { await stat(full); } catch { continue; }
    for await (const f of walk(full)) {
      await scanFile(f);
    }
  }
  await checkInvoiceKeyResolution();

  console.log(`\n=== Raw Key Leak Scanner ===\n`);
  console.log(`Scanned: ${SCAN_DIRS.join(', ')}`);
  console.log(`Findings: ${findings.length}\n`);

  if (findings.length === 0) {
    console.log('✓ No raw key leaks or banned hardcoded literals found.');
    process.exit(0);
  }

  // Group by file
  const byFile = {};
  for (const f of findings) {
    if (!byFile[f.file]) byFile[f.file] = [];
    byFile[f.file].push(f);
  }

  for (const [file, items] of Object.entries(byFile)) {
    console.log(`--- ${file} ---`);
    for (const it of items) {
      console.log(`  L${it.line} [${it.type}] ${it.token}`);
      console.log(`    ${it.snippet}`);
    }
  }
  process.exit(1);
}

main().catch(e => {
  console.error('Scanner crashed:', e);
  process.exit(2);
});
