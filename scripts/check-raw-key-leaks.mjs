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
  'dashboard', 'analysis', 'chat', 'common', 'common2', 'ai',
  'transactions', 'usTax', 'accounts', 'settings', 'header', 'nav',
  'onboarding', 'alerts', 'aiInsights', 'charts', 'documents',
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
      // usLabel/usLabelCount/localeLabel/genLabel/genLabelCount(taxKey, 'ns.key'[, n]):
      // the ns.key is the i18n fallback passed to the accountingLocale-aware wrapper
      // (resolved via t() for the CN/default locale), not a display-as-literal leak.
      if (new RegExp(`(usLabel|usLabelCount|localeLabel|genLabel|genLabelCount)\\s*\\([^)]*['"\`]${ns}\\.${key}['"\`]`).test(line)) continue;
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
// Scope note: this guards the advanced-filter LABELS plus the status-dropdown
// OPTION keys. The status options are the CN-accountingLocale fallback (non-CN
// locales resolve them via the generic invStatus* taxConcepts); they must still
// resolve in every locale file, because CN + any uiLanguage renders them through
// t() — a missing key leaked the raw `invoices.statusVerified` etc. in the
// dropdown. The advancedFilterActive / inputRecordCount / outputRecordCount count
// lines stay out (they carry {count} interpolation handled separately).
const REQUIRED_INVOICE_LABEL_KEYS = [
  'advancedFilter', 'clearAll', 'dateRange', 'amountRange',
  'weightRange', 'statusFilter', 'allStatus', 'min', 'max',
  'statusVerified', 'statusCertified', 'statusDeducted',
  'statusPendingCert', 'statusPendingInvoice', 'statusIssued',
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

// Money inputs render the currency symbol as an absolutely-positioned prefix
// (<span ...>{currSym}</span>) over the input. The input must reserve enough
// left padding for the symbol via the dynamic `moneyPad` class, otherwise a
// multi-char symbol (NT$) overlaps the placeholder/value. Guard: every
// currency-prefixed money input must use ${moneyPad}, and moneyPad must be defined.
async function checkMoneyInputPadding() {
  const files = ['components/PurchaseAndInputPage.tsx', 'components/SalesAndOutputPage.tsx'];
  for (const file of files) {
    let src;
    try { src = await readFile(join(ROOT, file), 'utf8'); } catch { continue; }
    const prefixCount = (src.match(/\{currSym\}<\/span>/g) || []).length;
    if (prefixCount === 0) continue;
    if (!/const moneyPad\s*=/.test(src)) {
      findings.push({
        file, line: 0, type: 'money-input-padding', token: 'moneyPad',
        snippet: `${prefixCount} currency-prefixed money input(s) but no dynamic moneyPad padding defined (NT$ would overlap the placeholder)`,
      });
    }
    const padCount = (src.match(/\$\{moneyPad\}/g) || []).length;
    if (padCount < prefixCount) {
      findings.push({
        file, line: 0, type: 'money-input-padding', token: 'moneyPad',
        snippet: `${prefixCount} currency-prefixed money input(s) but only ${padCount} use the dynamic moneyPad left-padding (a money input may overlap its currency prefix)`,
      });
    }
  }
}

// The inventory/quantity unit (product_unit) must be in the settings allowlist,
// otherwise it is filtered out on read and the dashboard/inventory cards always
// fall back to the generic 单位 instead of the configured unit (吨/袋/公斤…). The
// frontend already resolves it dynamically via getInventoryUnitLabel(productUnit).
async function checkProductUnitSetting() {
  let src;
  try { src = await readFile(join(ROOT, 'electron/handlers/settings.js'), 'utf8'); } catch { return; }
  if (/SETTINGS_ALLOWED_KEYS/.test(src) && !/['"]product_unit['"]/.test(src)) {
    findings.push({
      file: 'electron/handlers/settings.js', line: 0, type: 'settings-allowlist',
      token: 'product_unit',
      snippet: 'product_unit missing from SETTINGS_ALLOWED_KEYS — inventory cards would always fall back to the generic 单位 instead of the configured unit',
    });
  }
}

async function checkTaxSummaryTitleNoBreak() {
  // The tax-inclusive summary title (taxSummaryTitle) renders inside a flex h3 next
  // to an icon; without whitespace-nowrap the long CJK title breaks at word
  // boundaries and reads as "台湾 营业税 申报汇总（对账用）" instead of continuous text.
  // Pin the nowrap wrapper at both render sites so the title stays on one line.
  const sites = [
    { file: 'components/FinancePage.tsx', call: "lbl('taxSummaryTitle')" },
    { file: 'components/TaxInclusiveSummary.tsx', call: "label('taxSummaryTitle')" },
  ];
  for (const { file, call } of sites) {
    let src;
    try { src = await readFile(join(ROOT, file), 'utf8'); } catch { continue; }
    const idx = src.indexOf(call);
    if (idx === -1) continue;
    // the nowrap class lives on the wrapping span/h3 just before the label call
    const window = src.slice(Math.max(0, idx - 140), idx + 40);
    if (!/whitespace-nowrap/.test(window)) {
      findings.push({
        file, line: 0, type: 'tax-summary-title-nobreak', token: 'whitespace-nowrap',
        snippet: 'taxSummaryTitle render is missing whitespace-nowrap — the CJK title would break into "台湾 营业税 申报汇总" instead of continuous text',
      });
    }
  }
}

async function checkTransactionSummaryMoney() {
  // The 收支记录 summary cards (total income / expense / net) must use the
  // locale-aware money formatter (formatMoney → TW NT$0.00), not a bare number.
  let src;
  try { src = await readFile(join(ROOT, 'components/TransactionsPage.tsx'), 'utf8'); } catch { return; }
  if (!/formatMoney/.test(src)) {
    findings.push({
      file: 'components/TransactionsPage.tsx', line: 0, type: 'txn-summary-money', token: 'formatMoney',
      snippet: 'TransactionsPage summary totals must use formatMoney (locale currency, e.g. TW NT$0.00) — formatMoney not imported/used',
    });
    return;
  }
  for (const field of ['summary.income.total', 'summary.expense.total', 'summary.net']) {
    if (new RegExp(`fmt\\(${field.replace(/\./g, '\\.')}\\)`).test(src)) {
      findings.push({
        file: 'components/TransactionsPage.tsx', line: 0, type: 'txn-summary-money', token: field,
        snippet: `${field} still uses bare fmt() — summary totals must use the locale-aware money() formatter (TW NT$0.00)`,
      });
    }
  }
}

async function checkNoAutoAIAnalysis() {
  // The AI business briefing (performAnalysis, App.tsx) and the data-analysis forecast
  // (runAnalysis, DataAnalysisPage.tsx) must NOT auto-run on mount / navigation / HMR —
  // they depend on the accounting locale + UI language, so an auto useEffect hammers the
  // default provider and spams Gemini 429. AI must be user-triggered (a button click).
  let app;
  try { app = await readFile(join(ROOT, 'App.tsx'), 'utf8'); } catch { app = null; }
  if (app && /useEffect\(\s*\(\)\s*=>\s*\{\s*performAnalysis\(\)\s*;?\s*\}\s*,\s*\[\s*performAnalysis\s*\]\s*\)/.test(app)) {
    findings.push({
      file: 'App.tsx', line: 0, type: 'ai-auto-invoke', token: 'performAnalysis',
      snippet: 'performAnalysis() auto-runs in a useEffect — AI must be user-triggered (avoids Gemini 429 spam on mount/navigation/HMR)',
    });
  }
}

async function checkAIQuotaCooldown() {
  // A Gemini 429 / quota error must trigger a cooldown + friendly message instead of
  // re-requesting on every refresh (otherwise the console spams api:request errors).
  let src;
  try { src = await readFile(join(ROOT, 'App.tsx'), 'utf8'); } catch { return; }
  if (!/aiQuotaCooldownRef/.test(src)) {
    findings.push({
      file: 'App.tsx', line: 0, type: 'ai-quota-cooldown', token: 'aiQuotaCooldownRef',
      snippet: 'AI analysis lacks a 429/quota cooldown (aiQuotaCooldownRef) — a Gemini quota error would keep re-requesting and spam the console',
    });
  }
  if (!/aiInsights\.quotaExceeded/.test(src)) {
    findings.push({
      file: 'App.tsx', line: 0, type: 'ai-quota-cooldown', token: 'quotaExceeded',
      snippet: 'AI analysis does not surface the friendly aiInsights.quotaExceeded message on a Gemini 429',
    });
  }
}

async function checkAnalyticsMatrixDisplay() {
  // 年度数据全景矩阵 (DataAnalysisPage): amount cards must use the full money formatter
  // (formatMoney → ¥0.00, locale-correct) not the compact …k form, and the quantity must
  // NOT append a hardcoded product unit (吨/ton/…) — units belong to product/SKU settings.
  let src;
  try { src = await readFile(join(ROOT, 'components/DataAnalysisPage.tsx'), 'utf8'); } catch { return; }
  if (!/formatMoney\(item\.revenue/.test(src)) {
    findings.push({
      file: 'components/DataAnalysisPage.tsx', line: 0, type: 'analytics-matrix-money', token: 'formatMoney',
      snippet: '年度数据全景矩阵 month-card revenue should use formatMoney (¥0.00), not the compact …k form',
    });
  }
  if (/item\.salesTons\}\s*\{unitLabel\}/.test(src)) {
    findings.push({
      file: 'components/DataAnalysisPage.tsx', line: 0, type: 'analytics-matrix-unit', token: 'unitLabel',
      snippet: '年度数据全景矩阵 quantity must not append a fixed product unit (drop {unitLabel}); units belong to product/SKU settings',
    });
  }
}

async function checkFinanceMoneyFormat() {
  // 财务报表 (FinancePage): every money LineItem must go through the currency formatter
  // fmt() (= formatMoney → ¥0.00 / NT$0.00 …), never a bare numeric value that renders as
  // "0.00" without a symbol. Percentages/ratios pass pre-built strings ("…%") and are fine.
  let src;
  try { src = await readFile(join(ROOT, 'components/FinancePage.tsx'), 'utf8'); } catch { return; }
  const m = src.match(/value=\{\s*[0-9]/g);
  if (m) {
    findings.push({
      file: 'components/FinancePage.tsx', line: 0, type: 'finance-money-format', token: 'value={<number>}',
      snippet: `${m.length} LineItem(s) pass a bare numeric value (e.g. value={0.0}) — money must use fmt()/formatMoney so it shows the currency symbol (¥0.00), not a symbol-less 0.00`,
    });
  }
}

async function checkAIToolsReadonly() {
  // R2b-1: the AI assistant tool whitelist (electron/ai/tools.js) must stay READ-ONLY.
  // It may only map GET/summary/list/get handlers; it must NEVER reference a write handler
  // (create/update/remove/save/payment/issue/void/tax-invoice/migrate), and must NEVER touch
  // the API key / encrypted storage / DB restore. This is the machine lock behind
  // "AI can only read, never mutate / never see the key".
  let src;
  try {
    src = await readFile(join(ROOT, 'electron/ai/tools.js'), 'utf8');
  } catch {
    findings.push({
      file: 'electron/ai/tools.js', line: 0, type: 'ai-tools-missing', token: 'tools.js',
      snippet: 'R2b-1 expects electron/ai/tools.js (the read-only AI tool whitelist) to exist',
    });
    return;
  }
  const WRITE_CALL = /\.(create|update|remove|delete|save|batchSales|batchPurchases|recordSalePayment|recordPurchasePayment|updateTaxInvoice|resetToDefault|setDefault|migrateAll|rollback)\s*\(/;
  if (WRITE_CALL.test(src)) {
    findings.push({
      file: 'electron/ai/tools.js', line: 0, type: 'ai-tool-write', token: 'mutating-handler',
      snippet: 'AI tool file calls a write handler — assistant tools MUST be read-only (no create/update/remove/save/payment/issue/void/migrate)',
    });
  }
  if (/safeStorage|decryptKey|api_key|importDb|relaunch/.test(src)) {
    findings.push({
      file: 'electron/ai/tools.js', line: 0, type: 'ai-tool-sensitive', token: 'sensitive-ref',
      snippet: 'AI tool file must not reference API keys / encrypted storage / DB restore (safeStorage/decryptKey/api_key/importDb/relaunch)',
    });
  }
}

async function checkAIContextInvoiceStatus() {
  // R3a: the AI context aggregation (electron/handlers/ai.js) must NOT count invoices by
  // hard-equality to a single Chinese status (invoiceStatus === '已开' / '已收') — that makes
  // non-CN / CSV-imported (English: issued/paid/…) statuses count as 0. Use the locale-robust
  // isIssuedInvoiceStatus() helper (已开/已收/issued/paid/collected/invoiced) instead.
  let src;
  try { src = await readFile(join(ROOT, 'electron/handlers/ai.js'), 'utf8'); } catch { return; }
  if (/invoiceStatus\s*===\s*['"]已[开收]['"]/.test(src)) {
    findings.push({
      file: 'electron/handlers/ai.js', line: 0, type: 'ai-context-invoice-locale', token: 'invoiceStatus',
      snippet: 'AI context counts invoices by hard-equal to Chinese 已开/已收 — use the locale-robust isIssuedInvoiceStatus() (已开/已收/issued/paid/collected/invoiced)',
    });
  }
}

async function checkAIErrorCodes() {
  // R3c: AI errors must carry a STABLE code (aiError.* enum) and the renderer must map
  // code → i18n (follows uiLanguage). The main process must NOT emit localized Chinese
  // "friendly" strings, and provider parse failures must go through parseError (code=parseFailed),
  // never a bare Chinese `throw new Error('…解析失败')`.

  // (1) _error.js / gemini.js must not re-introduce a `friendly` field or Chinese friendly prose.
  for (const file of ['electron/ai/providers/_error.js', 'electron/ai/providers/gemini.js']) {
    let src;
    try { src = await readFile(join(ROOT, file), 'utf8'); } catch { continue; }
    // Match a re-introduced friendly FIELD / helper / assignment — not the word in an
    // explanatory comment ("不再生成 friendly 串").
    if (/\.friendly\b|friendlyHint|friendly\s*=|['"]friendly['"]\s*:/.test(src)) {
      findings.push({
        file, line: 0, type: 'ai-error-friendly', token: 'friendly',
        snippet: `${file} reintroduces a localized 'friendly' error string — AI errors must rely on a stable code (aiError.*), the renderer localizes via i18n`,
      });
    }
  }

  // (2) provider files must not throw bare Chinese parse-failure messages (use parseError → parseFailed).
  for (const file of ['electron/ai/providers/openai.js', 'electron/ai/providers/anthropic.js', 'electron/ai/providers/gemini.js']) {
    let src;
    try { src = await readFile(join(ROOT, file), 'utf8'); } catch { continue; }
    if (/throw new Error\(['"][^'"]*(解析失败|返回为空)/.test(src)) {
      findings.push({
        file, line: 0, type: 'ai-parse-no-code', token: 'parseFailed',
        snippet: `${file} throws a bare Chinese parse-failure Error — use parseError(LABEL, …) so it carries the stable parseFailed code`,
      });
    }
  }

  // (3) the api:request IPC catch must embed the stable code via the AI_ERR:<code> prefix.
  {
    let src;
    try { src = await readFile(join(ROOT, 'electron/handlers/index.js'), 'utf8'); } catch { src = null; }
    if (src && !/AI_ERR:\$\{code\}/.test(src)) {
      findings.push({
        file: 'electron/handlers/index.js', line: 0, type: 'ai-error-no-token', token: 'AI_ERR',
        snippet: "api:request catch must prefix the message with AI_ERR:${code} so the renderer can deterministically extract the stable code (Electron IPC drops Error custom fields)",
      });
    }
  }

  // (4) the renderer code→i18n helper must exist.
  {
    let src;
    try { src = await readFile(join(ROOT, 'services/aiErrors.ts'), 'utf8'); } catch { src = null; }
    if (!src || !/parseAiErrorCode/.test(src) || !/aiErrorMessage/.test(src)) {
      findings.push({
        file: 'services/aiErrors.ts', line: 0, type: 'ai-error-helper-missing', token: 'aiErrors',
        snippet: 'services/aiErrors.ts must export parseAiErrorCode + aiErrorMessage (the code→i18n mapping the AI surfaces depend on)',
      });
    }
  }

  // (5) the AI business surfaces must consume the helper (no regressing to a hardcoded fallback).
  const CONSUMERS = [
    'components/assistant/useAssistant.ts',
    'App.tsx',
  ];
  for (const file of CONSUMERS) {
    let src;
    try { src = await readFile(join(ROOT, file), 'utf8'); } catch { continue; }
    if (!/aiErrorMessage|parseAiErrorCode/.test(src)) {
      findings.push({
        file, line: 0, type: 'ai-error-not-mapped', token: 'aiErrorMessage',
        snippet: `${file} must map AI errors via services/aiErrors (aiErrorMessage / parseAiErrorCode), not a hardcoded fallback message`,
      });
    }
  }
}

async function checkNoTTSResidue() {
  // R4c: voice/TTS was removed in R1; the external supportsTTS capability field / badge
  // and the stale "GEMINI 3 FLASH" model name must not return.
  // NOTE: the provider adapter META `capabilities.tts: false` + dead `tts()` methods are
  // intentionally LEFT — this check does NOT scan electron/ai/providers/*.js.
  // (1) no supportsTTS external field / badge in the type, the IPC list(), or the consuming components
  for (const file of ['types.ts', 'electron/ai/index.js', 'components/ProvidersSection.tsx', 'components/OnboardingWizard.tsx']) {
    let src;
    try { src = await readFile(join(ROOT, file), 'utf8'); } catch { continue; }
    if (/supportsTTS/.test(src)) {
      findings.push({
        file, line: 0, type: 'tts-residue', token: 'supportsTTS',
        snippet: `${file} references supportsTTS — TTS/voice was removed (R1); do not re-expose the TTS capability field/badge`,
      });
    }
    if (/支持\s*TTS|支援\s*TTS/.test(src)) {
      findings.push({
        file, line: 0, type: 'tts-residue', token: '支持 TTS',
        snippet: `${file} hardcodes a 「支持 TTS」 badge — TTS was removed (R1)`,
      });
    }
  }
  // (2) i18n must not carry the stale "GEMINI 3 FLASH" model name (multi-provider now)
  for (const lang of ['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr']) {
    const file = `i18n/locales/${lang}.json`;
    let src;
    try { src = await readFile(join(ROOT, file), 'utf8'); } catch { continue; }
    if (/GEMINI 3 FLASH/i.test(src)) {
      findings.push({
        file, line: 0, type: 'stale-model-name', token: 'GEMINI 3 FLASH',
        snippet: `${file} hardcodes the stale model name "GEMINI 3 FLASH" — use generic AI wording (multi-provider)`,
      });
    }
  }
}

async function checkConversationsNoSecrets() {
  // R4a-1: the AI assistant conversation store (electron/handlers/conversations.js) persists
  // chat history ONLY. It must NEVER touch the API key / encrypted storage, and must only
  // read/write the assistant_* tables — never a business table. This is the machine lock
  // behind "session tables don't store the key / any sensitive business detail".
  let src;
  try {
    src = await readFile(join(ROOT, 'electron/handlers/conversations.js'), 'utf8');
  } catch {
    findings.push({
      file: 'electron/handlers/conversations.js', line: 0, type: 'conversations-missing', token: 'conversations.js',
      snippet: 'R4a-1 expects electron/handlers/conversations.js (the conversation persistence handler) to exist',
    });
    return;
  }
  // (1) must not reference the API key / encrypted storage / DB restore
  if (/safeStorage|decryptKey|encryptKey|api_key|importDb|relaunch/.test(src)) {
    findings.push({
      file: 'electron/handlers/conversations.js', line: 0, type: 'conversations-sensitive', token: 'sensitive-ref',
      snippet: 'conversations.js must not reference API keys / encrypted storage / DB restore (safeStorage/decryptKey/api_key/importDb/relaunch) — session store is non-sensitive',
    });
  }
  // (2) every write must target an assistant_* table (never a business table)
  const writeRe = /\b(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+([A-Za-z_][A-Za-z0-9_]*)/gi;
  let m;
  while ((m = writeRe.exec(src)) !== null) {
    const table = m[2];
    if (!/^assistant_/.test(table)) {
      findings.push({
        file: 'electron/handlers/conversations.js', line: 0, type: 'conversations-foreign-write', token: table,
        snippet: `conversations.js writes to non-assistant table "${table}" — the conversation handler must only touch assistant_conversations / assistant_messages`,
      });
    }
  }
}

async function checkAgentBudget() {
  // R4b: the read-only agent loop's guardrails must stay in place — MAX_ROUNDS / MAX_ROWS (R2b-1)
  // and the R4b token budget MAX_TOKENS. Removing the budget would let a runaway loop accumulate
  // unbounded context (cost / context-window risk). Lock that all three caps remain declared.
  let src;
  try { src = await readFile(join(ROOT, 'electron/ai/agent.js'), 'utf8'); } catch { return; }
  for (const cap of ['MAX_ROUNDS', 'MAX_ROWS', 'MAX_TOKENS']) {
    if (!new RegExp(`\\b${cap}\\b`).test(src)) {
      findings.push({
        file: 'electron/ai/agent.js', line: 0, type: 'agent-guardrail-missing', token: cap,
        snippet: `agent.js must keep the ${cap} guardrail — round / row / token caps bound the read-only agent loop; do not remove`,
      });
    }
  }
}

async function checkVisionOcrNoPersist() {
  // PR-3b: vision OCR sends the invoice image as base64 to the provider, but the image / its base64 /
  // the extracted invoice detail must NEVER be persisted into the assistant_* conversation tables.
  // (1) the OpenAI-compatible provider (which now does vision OCR) must stay persistence-free.
  let factory = '';
  try { factory = await readFile(join(ROOT, 'electron/ai/providers/_openaiCompatible.js'), 'utf8'); } catch { factory = ''; }
  // Match real usage (calls / member access / table names), not the word in a comment.
  if (/getDb\s*\(|safeStorage\s*\.|assistant_messages|appendMessage\s*\(|require\(['"][^'"]*conversations/.test(factory)) {
    findings.push({
      file: 'electron/ai/providers/_openaiCompatible.js', line: 0, type: 'vision-ocr-persist', token: 'persistence-ref',
      snippet: 'the OpenAI-compatible provider (vision OCR) must not touch the DB / safeStorage / conversation store',
    });
  }
  // (2) no source may write image base64 into the assistant_messages store.
  for (const dir of ['electron', 'components', 'services']) {
    const base = join(ROOT, dir);
    try { await stat(base); } catch { continue; }
    for await (const f of walk(base)) {
      let src;
      try { src = await readFile(f, 'utf8'); } catch { continue; }
      if (/appendMessage\s*\([^)]*base64/i.test(src) || /INSERT\s+INTO\s+assistant_messages[\s\S]{0,400}base64/i.test(src)) {
        findings.push({
          file: f.replace(`${ROOT}/`, ''), line: 0, type: 'vision-ocr-persist', token: 'base64-into-conversation',
          snippet: 'image base64 must never be written into assistant_messages — OCR detail stays out of chat persistence',
        });
      }
    }
  }
}

async function checkProviderLogosLocal() {
  // BYOK provider card logos must be LOCAL assets (assets/provider-logos/, bundled via Vite) — never a
  // remote/CDN URL or an inlined base64. providerLogos.ts is the single source; the two card renderers
  // must use it (a local imported url), not a hardcoded <img src="http..."> or a data: image.
  for (const rel of ['components/providerLogos.ts', 'components/ProvidersSection.tsx', 'components/OnboardingWizard.tsx']) {
    let src;
    try { src = await readFile(join(ROOT, rel), 'utf8'); } catch { continue; }
    if (/src\s*=\s*["'`]\s*https?:\/\//i.test(src)) {
      findings.push({ file: rel, line: 0, type: 'remote-logo', token: 'remote-src',
        snippet: `${rel}: provider logo <img> must use a local imported asset, not a remote/CDN src` });
    }
    if (/data:image\//i.test(src)) {
      findings.push({ file: rel, line: 0, type: 'inline-logo', token: 'data:image',
        snippet: `${rel}: provider logos must not be inlined as base64 data: images` });
    }
  }
  // providerLogos.ts must resolve from the local assets dir and reference no http(s) URL.
  let pl;
  try { pl = await readFile(join(ROOT, 'components/providerLogos.ts'), 'utf8'); } catch { pl = ''; }
  if (pl) {
    if (!/assets\/provider-logos/.test(pl)) {
      findings.push({ file: 'components/providerLogos.ts', line: 0, type: 'logo-source', token: 'assets/provider-logos',
        snippet: 'providerLogos.ts must resolve logos from assets/provider-logos (local, bundled)' });
    }
    if (/https?:\/\//i.test(pl)) {
      findings.push({ file: 'components/providerLogos.ts', line: 0, type: 'remote-logo', token: 'http',
        snippet: 'providerLogos.ts must not reference any http(s) URL — logos are local only' });
    }
  }
  // vite.config must keep provider logos OUT of base64 inlining → emitted as standalone files,
  // not data: URIs (Vite inlines assets < 4KB by default). Lock the assetsInlineLimit rule.
  let vc;
  try { vc = await readFile(join(ROOT, 'vite.config.ts'), 'utf8'); } catch { vc = ''; }
  if (!/assetsInlineLimit/.test(vc) || !/provider-logos/.test(vc)) {
    findings.push({ file: 'vite.config.ts', line: 0, type: 'logo-inline-guard', token: 'assetsInlineLimit',
      snippet: 'vite.config.ts must set build.assetsInlineLimit to NOT inline provider-logos (keep them standalone files, not base64 data: URIs)' });
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
  await checkMoneyInputPadding();
  await checkProductUnitSetting();
  await checkTaxSummaryTitleNoBreak();
  await checkTransactionSummaryMoney();
  await checkNoAutoAIAnalysis();
  await checkAIQuotaCooldown();
  await checkAIToolsReadonly();
  await checkAIContextInvoiceStatus();
  await checkAIErrorCodes();
  await checkNoTTSResidue();
  await checkConversationsNoSecrets();
  await checkAgentBudget();
  await checkVisionOcrNoPersist();
  await checkProviderLogosLocal();
  await checkAnalyticsMatrixDisplay();
  await checkFinanceMoneyFormat();

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
