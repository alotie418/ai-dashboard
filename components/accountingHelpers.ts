// Accounting Helpers — 格式化 + 标签查找，核心入口
//
// 所有 helper 都接收两个参数：
//   accountingLocale: 决定"用什么财务逻辑"（税种 / 币种 / 报表结构）
//   uiLanguage: 决定"用什么语言显示"（标签文字）
//
// 二者互不推导。

import {
  getAccountingLocale,
  ACCOUNTING_LOCALES,
  type AccountingLocaleId,
  type UILanguageCode,
  type AccountingLocaleConfig,
} from './accountingLocaleConfig';

// ─── Currency Formatting ───

export function formatMoney(
  amount: number,
  accountingLocale: string,
  _uiLanguage?: string, // reserved for future locale-aware number format
): string {
  const config = getAccountingLocale(accountingLocale);
  const abs = Math.abs(amount || 0);
  const formatted = abs.toLocaleString(undefined, {
    minimumFractionDigits: config.defaultCurrency === 'JPY' || config.defaultCurrency === 'KRW' ? 0 : 2,
    maximumFractionDigits: config.defaultCurrency === 'JPY' || config.defaultCurrency === 'KRW' ? 0 : 2,
  });
  const sign = amount < 0 ? '-' : '';
  return `${sign}${config.currencySymbol}${formatted}`;
}

export function getCurrencySymbol(accountingLocale: string): string {
  return getAccountingLocale(accountingLocale).currencySymbol;
}

// Compact money for analytics cards/axes: `${symbol}${value/1000}k` (e.g. $1.2k).
// Chinese UI (zh-CN/zh-TW): a value that rounds to zero at the shown precision renders
// as a plain `${symbol}0` (e.g. ¥0 / ₩0) — never ¥0k / ¥0.0k — for EVERY accountingLocale.
// Other UI languages keep the existing compact `…k` format unchanged. Non-zero values
// always keep `…k`. Symbol always follows accountingLocale.
export function formatCompactMoney(
  value: number,
  accountingLocale: string,
  uiLanguage: string,
  fractionDigits: number = 1,
): string {
  const sym = getCurrencySymbol(accountingLocale);
  const compact = ((value || 0) / 1000).toFixed(fractionDigits);
  const isZh = uiLanguage === 'zh-CN' || uiLanguage === 'zh-TW';
  if (isZh && parseFloat(compact) === 0) return `${sym}0`;
  return `${sym}${compact}k`;
}

export function getCurrency(accountingLocale: string): string {
  return getAccountingLocale(accountingLocale).defaultCurrency;
}

// ─── Tax Concept Labels ───
// 根据 accountingLocale 确定"该国有什么税种"，根据 uiLanguage 确定"用什么语言显示"

export function getTaxLabel(
  accountingLocale: string,
  uiLanguage: string,
  key: string,
): string {
  const config = getAccountingLocale(accountingLocale) as any;
  // Search in taxConcepts first, then at config root (for invoice labels that may be at either level)
  const concept = config.taxConcepts?.[key] || config[key];
  if (!concept || typeof concept !== 'object') return key;

  // Lookup chain: exact lang → base lang (e.g. zh-TW → zh-CN) → en → first available
  return concept[uiLanguage]
    || concept[uiLanguage.split('-')[0]]
    || concept['en']
    || Object.values(concept)[0]
    || key;
}

// ─── Report / P&L Labels ───
// 报表行标签按 accountingLocale 选择"哪些行"，按 uiLanguage 选择"怎么翻译"

export function getReportLabel(
  accountingLocale: string,
  uiLanguage: string,
  key: string,
): string {
  // Report labels live in taxConcepts too (pl* prefix keys)
  return getTaxLabel(accountingLocale, uiLanguage, key);
}

// ─── Dashboard Sections ───
// 仪表盘显示哪些卡片由 accountingLocale 决定，不受 uiLanguage 影响

export function getDashboardSections(accountingLocale: string): string[] {
  return getAccountingLocale(accountingLocale).dashboardSections;
}

// ─── Category Display Label ───
// 类别由 accountingLocale 决定集合，显示名由 uiLanguage 决定

export function getCategoryDisplayLabel(
  category: { label_zh_cn: string; label_zh_tw?: string | null; label_en: string; label_ja?: string | null; label_ko?: string | null; label_fr?: string | null },
  uiLanguage: string,
): string {
  const map: Record<string, string | null | undefined> = {
    'zh-CN': category.label_zh_cn,
    'zh-TW': category.label_zh_tw,
    en: category.label_en,
    ja: category.label_ja,
    ko: category.label_ko,
    fr: category.label_fr,
  };
  return map[uiLanguage] || map['en'] || category.label_zh_cn || category.label_en;
}

// ─── AI Prompt Context ───
// AI prompt 同时注入 accountingLocale 的会计规则 + uiLanguage 的语言指令

export function buildAIFinanceContext(
  accountingLocale: string,
  uiLanguage: string,
): string {
  const config = getAccountingLocale(accountingLocale);

  const langInstructions: Record<string, string> = {
    'zh-CN': '请使用简体中文回答。',
    'zh-TW': '請使用繁體中文回答。',
    en: 'Please respond in English.',
    ja: '日本語で回答してください。',
    ko: '한국어로 답변해 주세요.',
    fr: 'Veuillez répondre en français.',
  };

  const langInstruction = langInstructions[uiLanguage] || langInstructions['en'];
  // KR + Chinese UI: steer the AI briefing's VAT wording to match the dashboard
  // (采购 VAT / 销售 VAT), not CN-VAT 进项/销项/增值税 or JP 消费税. Gated to KR + zh
  // so CN/JP/EU/US and en/ja/ko/fr contexts are unchanged.
  const krZhDirective = (accountingLocale === 'KR' && (uiLanguage === 'zh-CN' || uiLanguage === 'zh-TW'))
    ? (uiLanguage === 'zh-CN'
        ? '\n\n韩国 VAT 制度：中文简报请统一使用「采购 VAT」「销售 VAT」「应缴 VAT」等表述（与界面一致）。'
        : '\n\n韓國 VAT 制度：中文簡報請統一使用「採購 VAT」「銷售 VAT」「應繳 VAT」等表述（與介面一致）。')
    : '';
  return `${config.aiContext}\n\n${langInstruction}${krZhDirective}`;
}

// ─── Convenience: get full config ───

export function getLocaleConfig(accountingLocale: string): AccountingLocaleConfig {
  return getAccountingLocale(accountingLocale);
}

// ─── Finance Report Helpers ───
// accountingLocale 决定显示哪些 tab 和税务模块
// uiLanguage 决定 tab 标签的语言

export interface FinanceReportTab {
  id: 'pl' | 'balance' | 'cashflow';
  labelKey: string;       // i18n key (for common tabs like balance/cashflow)
  localeLabelKey?: string; // taxConcepts key (for locale-specific labels like Schedule C)
}

export function getFinanceReportTabs(accountingLocale: string): FinanceReportTab[] {
  // All locales currently share the same 3 tabs (P&L, Balance, Cashflow).
  // The P&L tab label varies by locale (Schedule C vs 损益表 vs 損益計算書).
  return [
    { id: 'pl', labelKey: '', localeLabelKey: 'tabPlLabel' },
    { id: 'balance', labelKey: 'finance.tabBalance' },
    { id: 'cashflow', labelKey: 'finance.tabCashflow' },
  ];
}

// Should the VAT/Consumption Tax/Business Tax module render?
// US (Schedule C) does not use VAT-style accumulation. Other locales do.
export function shouldShowTaxModule(accountingLocale: string): boolean {
  return accountingLocale !== 'US';
}

// Should the tax-inclusive reconciliation section render?
// Same rule: US uses cash basis with sales tax, not VAT reconciliation.
export function shouldShowTaxInclusiveSummary(accountingLocale: string): boolean {
  return accountingLocale !== 'US';
}

// ─── Inventory Unit Labels ───
// 库存单位由产品/业务设置决定，不绑定 accountingLocale
// uiLanguage 只决定单位名称的显示语言

const INVENTORY_UNIT_LABELS: Record<string, Record<string, string>> = {
  unit:  { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units',  ja: '単位',  ko: '단위',  fr: 'unités' },
  kg:    { 'zh-CN': '千克', 'zh-TW': '公斤', en: 'kg',     ja: 'kg',    ko: 'kg',    fr: 'kg' },
  ton:   { 'zh-CN': '吨',   'zh-TW': '噸',   en: 'tons',   ja: 'トン',  ko: '톤',    fr: 'tonnes' },
  piece: { 'zh-CN': '件',   'zh-TW': '件',   en: 'pcs',    ja: '個',    ko: '개',    fr: 'pièces' },
  box:   { 'zh-CN': '箱',   'zh-TW': '箱',   en: 'boxes',  ja: '箱',    ko: '상자',  fr: 'cartons' },
  bag:   { 'zh-CN': '袋',   'zh-TW': '袋',   en: 'bags',   ja: '袋',    ko: '포대',  fr: 'sacs' },
  liter: { 'zh-CN': '升',   'zh-TW': '公升', en: 'L',      ja: 'L',     ko: 'L',     fr: 'L' },
};

export type InventoryUnitKey = 'unit' | 'kg' | 'ton' | 'piece' | 'box' | 'bag' | 'liter';

export function getInventoryUnitLabel(unitKey: string | null | undefined, uiLanguage: string): string {
  // No explicit business unit → no label, so quantities render as pure numbers.
  // 'ton' is the legacy default (single-product origin) and 'unit' is the generic
  // placeholder; both are treated as "unconfigured". Any other explicit unit
  // (kg/piece/box/bag/liter) still shows, for when a unit-picker is added later.
  if (!unitKey || unitKey === 'ton' || unitKey === 'unit') return '';
  const entry = INVENTORY_UNIT_LABELS[unitKey];
  if (!entry) return '';
  return entry[uiLanguage] || entry[uiLanguage.split('-')[0]] || entry.en || '';
}

// 格式化数量 + 单位，例如 "0.00 單位" / "100 tons"
export function formatQuantity(
  amount: number,
  unitKey: string | null | undefined,
  uiLanguage: string,
  decimals: number = 2,
): string {
  const label = getInventoryUnitLabel(unitKey, uiLanguage);
  const n = (amount || 0).toFixed(decimals);
  return label ? `${n} ${label}` : n;
}

// Format a legacy string-typed quantity ("10吨" or "10") for display.
// If the string already carries any non-digit / non-whitespace / non-dot suffix,
// pass through unchanged (preserves user-typed unit).
// Otherwise append the locale-aware unit label.
export function formatLegacyQuantity(
  quantity: string | null | undefined,
  unitKey: string | null | undefined,
  uiLanguage: string,
): string {
  const s = (quantity ?? '').trim();
  if (!s) return '';
  if (/[^\d.\s]/.test(s)) return s;
  const label = getInventoryUnitLabel(unitKey, uiLanguage);
  return label ? `${s} ${label}` : s;
}

export { ACCOUNTING_LOCALES, type AccountingLocaleId, type UILanguageCode };
