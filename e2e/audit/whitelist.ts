// Whitelist + known-limitation constants for the UI-audit smoke harness (phase 1).
//
// These are intentionally SMALL and conservative. The goal is to suppress only
// OBVIOUS false positives without ever hiding a real UI defect. Anything that is
// genuinely ambiguous is kept as a finding with `possibleFalsePositive: true`
// rather than silently dropped here.

/** Number-abbreviation false positives: a BARE `<digit>K/M` is not a money/quantity
 *  abbreviation when its surrounding context is technical (model context windows,
 *  token counts, model ids). Currency-prefixed abbreviations are NEVER whitelisted. */
export const ABBREV_TECH_CONTEXT = ['context', 'token', 'ctx', 'model', 'temperature', 'param', 'window'];

/** Keyboard-shortcut markers — a `…K` adjacent to one of these is a shortcut, not money. */
export const SHORTCUT_MARKERS = ['⌘', '⌃', '⇧', '⌥', 'Ctrl', 'Cmd', 'Alt', 'Shift', '^'];

/** Raw-i18n-key false positives: a `<word>.<word>` token whose FINAL segment is one of
 *  these is a filename / domain / version, not a leaked translation key. (Text scanning
 *  already excludes <a href>, <code>, <kbd>, <input>, so most URLs/paths never reach here.) */
export const RAW_KEY_SUFFIX_WHITELIST = new Set([
  'com', 'org', 'io', 'net', 'cn', 'co', 'dev',
  'json', 'ts', 'tsx', 'js', 'mjs', 'png', 'jpg', 'jpeg', 'svg',
  'csv', 'pdf', 'db', 'md', 'html', 'css', 'zip', 'xlsx', 'txt',
]);

// ─────────────────────────────────────────────────────────────────────────────
// zh-CN / zh-TW Simplified vs Traditional purity char sets.
//
// Kept here so the simplified/traditional-leak rule INTERFACE exists and is wired,
// but the phase-1 smoke matrix does NOT run zh-CN / zh-TW combos. These are reused
// verbatim from e2e/locale-matrix.spec.ts so a later phase can enable the rule
// without re-deriving the character sets.
// ─────────────────────────────────────────────────────────────────────────────
export const ZH_SIMP_ONLY =
  '务报单发资应进销项额总户营关转库类数据显实现产业会计帐账团价风财购费贵质软输边过还这远连选录钱错门问间队页题验证设论说请读谢识译试详语调谈课规视见觉访评诺贸贺贴赞跃较递邮钟铁银锁难韩顺颗颜饭饮馆骤东车书长岁两广严丰临为乌乐习乡买乱争亏阳';
export const ZH_TRAD_ONLY =
  '務報單發資應進銷項額總戶營關轉庫類數據顯實現產業會計帳賬團價風財購費貴質軟輸邊過還這遠連選錄錢錯門問間隊頁題驗證設論說請讀謝識譯試詳語調談課規視見覺訪評諾貿賀貼讚躍較遞郵鐘鐵銀鎖難韓順顆顏飯飲館驟東車書長歲兩廣嚴豐臨為烏樂習鄉買亂爭虧陽';
