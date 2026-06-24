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

// ─────────────────────────────────────────────────────────────────────────────
// Phase-2 candidate-detection whitelists (heuristic — keep conservative).
//
// All token comparisons are lowercased. Tokens shorter than 3 letters are skipped
// by the rule itself, so 1–2 letter codes (AI, ID, NT, OS, JD) need not be listed.
// ─────────────────────────────────────────────────────────────────────────────

/** Legitimate everywhere: acronyms, codes, currency letters, platforms, AI providers.
 *  A Latin token matching one of these is NOT flagged as English residue in any UI. */
export const GLOBAL_TOKEN_WHITELIST = new Set<string>([
  // technical / acronyms
  'api', 'csv', 'pdf', 'ocr', 'sku', 'kpi', 'gst', 'ein', 'irs', 'url', 'upc', 'ean',
  'isbn', 'json', 'html', 'css', 'http', 'https', 'xml', 'b2b', 'b2c', 'faq', 'qr',
  'png', 'jpg', 'jpeg', 'svg', 'uuid', 'p&l', 'r&d', 'byok',
  // product / brand names (intentionally not localized)
  'sololedger',
  // tax-regime concept tokens that legitimately stay English/Latin across locales
  'vat', 'tva', 'schedule',
  // currency codes (letters)
  'usd', 'eur', 'cny', 'jpy', 'krw', 'twd', 'rmb', 'hkd', 'gbp', 'nt$',
  // marketplaces / platforms
  'amazon', 'temu', 'ebay', 'shopee', 'shopify', 'tiktok', 'taobao', 'tmall',
  'pinduoduo', 'alibaba', 'walmart', 'etsy',
  // AI providers / model families
  'gpt', 'claude', 'gemini', 'deepseek', 'qwen', 'kimi', 'glm', 'doubao',
  'openai', 'anthropic', 'google', 'azure', 'moonshot', 'zhipu',
]);

/** Smoke mock-fixture data (e2e/helpers/fixtures.ts) that may render in chrome regions
 *  (company name / unit / industry). Whitelisted so seeded English data is not flagged. */
export const MOCK_FIXTURE_WHITELIST = new Set<string>([
  'test', 'tester', 'item-a', 'item', 'ton', 'trade', 'piece',
]);

/** French ⇄ English homographs (same spelling) — correct French, never English residue.
 *  Derived from the documented cognates in scripts/check-i18n-placeholders.mjs (FR_ALLOW_EQ_EN)
 *  plus common UI homographs. fr residue uses a denylist, so this is a belt-and-suspenders guard. */
export const FR_COGNATE_WORDS = new Set<string>([
  'date', 'total', 'action', 'actions', 'type', 'types', 'min', 'max', 'volume',
  'dimension', 'mom', 'yoy', 'suggestion', 'suggestions', 'note', 'notes', 'format',
  'service', 'services', 'document', 'documents', 'option', 'options', 'description',
  'distribution', 'information', 'transaction', 'transactions', 'configuration',
  'image', 'images', 'stock', 'menu', 'contact', 'solution', 'client', 'clients',
  'article', 'articles', 'source', 'position', 'question', 'message', 'messages',
  'table', 'version', 'simple', 'double', 'route', 'page', 'pages', 'import', 'export',
  'profit', 'balance', 'occasion', 'commerce', 'finance', 'budget', 'plus',
]);

/** fr is Latin-script, so we cannot tell English from French structurally. v1 flags ONLY
 *  these curated English-only UI words (NOT French, NOT in FR_COGNATE_WORDS). Low recall,
 *  low false-positive — fr residue findings are P3 / possibleFalsePositive. */
export const ENGLISH_RESIDUE_DENYLIST = new Set<string>([
  'save', 'cancel', 'delete', 'edit', 'add', 'remove', 'search', 'loading', 'settings',
  'setting', 'submit', 'confirm', 'close', 'open', 'new', 'create', 'update', 'upload',
  'download', 'scan', 'rate', 'sales', 'sale', 'purchase', 'purchases', 'amount',
  'quantity', 'supplier', 'customer', 'invoice', 'invoices', 'overview', 'summary',
  'inventory', 'dashboard', 'status', 'pending', 'paid', 'unpaid', 'partial', 'draft',
  'name', 'price', 'cost', 'revenue', 'expense', 'expenses', 'income', 'payment',
  'payments', 'product', 'products', 'category', 'categories', 'unit', 'today',
  'month', 'year', 'week', 'day', 'received', 'issued',
]);

/** Simplified-Chinese characters in ZH_SIMP_ONLY that are ALSO valid Japanese shinjitai
 *  (identical glyph), so they appear in NORMAL Japanese text (数量 / 会計 / …) and must
 *  NOT be treated as a Chinese leak under ja. Subtracted from the ja chinese-leak check
 *  so it flags only simplified forms whose Japanese equivalent differs (报→報, 资→資, …).
 *  This is the empirically-required fix: bare ZH_SIMP_ONLY flagged valid kanji like 数/会. */
export const JP_SHARED_SIMPLIFIED = new Set<string>([...'数会乱争据']);
