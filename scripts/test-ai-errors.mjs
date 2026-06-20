#!/usr/bin/env node
// PR-6 §J: unit test for the frontend error-code mapping (services/aiErrors.ts pure functions).
// Run with `node scripts/test-ai-errors.mjs` — Node (v23.6+) strips TS types natively when a .ts
// module is imported directly, so we exercise the app's real source (no build step).
// Locks: AI_ERR:<code> extraction, regex fallback by status/keyword, clamp-to-'unknown',
// code → i18n leaf (aiError.<code>), J9 no-secret-leak, and aiError.* i18n completeness × 6 locales.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { parseAiErrorCode, safeAiErrorCode, aiErrorMessageFromCode, aiErrorMessage, AI_ERROR_CODES } from '../services/aiErrors.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const failures = [];
const check = (name, cond, detail) => { if (cond) console.log(`  ✓ ${name}`); else { console.log(`  ✗ ${name}${detail ? ' — ' + detail : ''}`); failures.push(name); } };
const t = (k) => k; // identity stub → returns the i18n key, so we can assert the leaf

console.log('\n=== aiErrors.ts mapping (PR-6 §J) ===\n');

// 1. AI_ERR:<code> tag extraction (the canonical IPC path)
for (const code of ['auth', 'permission', 'quota', 'modelNotFound', 'badRequest', 'serverError', 'parseFailed', 'emptyResponse', 'network', 'timeout', 'noProvider', 'unknown']) {
  check(`parseAiErrorCode AI_ERR:${code}`, parseAiErrorCode(`AI_ERR:${code} (debug info)`) === code);
}
// 2. unknown / non-enum AI_ERR tag → clamps to 'unknown'
check('parseAiErrorCode AI_ERR:bogus → unknown', parseAiErrorCode('AI_ERR:bogus x') === 'unknown');

// 3. regex fallback (no AI_ERR tag — web/timeout origins)
check('regex 401 → auth', parseAiErrorCode('HTTP 401 unauthorized') === 'auth');
check('regex 403 → permission', parseAiErrorCode('403 forbidden') === 'permission');
check('regex 429 → quota', parseAiErrorCode('429 rate limit exceeded') === 'quota');
check('regex 404 model not found → modelNotFound', parseAiErrorCode('404 model not found') === 'modelNotFound');
check('regex 400 → badRequest', parseAiErrorCode('400 bad_request') === 'badRequest');
check('regex 500 → serverError', parseAiErrorCode('500 server error') === 'serverError');
check('regex timeout → timeout', parseAiErrorCode('request timeout') === 'timeout');
check('regex 超时 → timeout', parseAiErrorCode('请求超时') === 'timeout');
check('regex parse → parseFailed', parseAiErrorCode('failed to parse response') === 'parseFailed');
check('regex 解析 → parseFailed', parseAiErrorCode('解析失败') === 'parseFailed');
check('regex network → network', parseAiErrorCode('network error econnrefused') === 'network');
check('no match → unknown', parseAiErrorCode('something weird happened') === 'unknown');

// 4. safeAiErrorCode clamp
check('safe known → itself', safeAiErrorCode('auth') === 'auth');
check('safe bogus → unknown', safeAiErrorCode('bogus') === 'unknown');
check('safe undefined → unknown', safeAiErrorCode(undefined) === 'unknown');
check('safe null → unknown', safeAiErrorCode(null) === 'unknown');

// 5. aiErrorMessageFromCode → aiError.<safeCode>
check('msgFromCode auth → aiError.auth', aiErrorMessageFromCode('auth', t) === 'aiError.auth');
check('msgFromCode undefined → aiError.unknown', aiErrorMessageFromCode(undefined, t) === 'aiError.unknown');
check('msgFromCode bogus → aiError.unknown', aiErrorMessageFromCode('bogus', t) === 'aiError.unknown');

// 6. aiErrorMessage(Error)
check('aiErrorMessage(AI_ERR:auth) → aiError.auth', aiErrorMessage(new Error('AI_ERR:auth (401)'), t) === 'aiError.auth');

// 7. J9 no-leak: a message containing a key still maps to a clean enum code, and the i18n leaf
//    never echoes the key (frontend renders only aiError.<code>, never providerMessage here).
check('J9 parseAiErrorCode with sk- key → enum code', AI_ERROR_CODES.includes(parseAiErrorCode('auth failed sk-ant-SECRET123456 401')));
check('J9 msgFromCode returns only the i18n key (no key echo)', !/sk-/.test(aiErrorMessageFromCode('auth', t)));

// 8. i18n completeness: every stable code has a non-empty aiError.<code> in all 6 locales
const LOCALES = ['en', 'zh-CN', 'zh-TW', 'ja', 'ko', 'fr'];
for (const lng of LOCALES) {
  const j = JSON.parse(readFileSync(join(ROOT, 'i18n', 'locales', `${lng}.json`), 'utf8'));
  const ae = (j && j.aiError) || {};
  for (const code of AI_ERROR_CODES) {
    check(`i18n ${lng} aiError.${code} present`, typeof ae[code] === 'string' && ae[code].length > 0);
  }
}

console.log(`\nFailures: ${failures.length}\n`);
if (failures.length) { for (const f of failures) console.error('  ✗ ' + f); process.exit(1); }
console.log('✓ aiErrors: all cases passed');
