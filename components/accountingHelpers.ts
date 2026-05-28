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
  return `${config.aiContext}\n\n${langInstruction}`;
}

// ─── Convenience: get full config ───

export function getLocaleConfig(accountingLocale: string): AccountingLocaleConfig {
  return getAccountingLocale(accountingLocale);
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
  const key = unitKey || 'unit';
  const entry = INVENTORY_UNIT_LABELS[key] || INVENTORY_UNIT_LABELS.unit;
  return entry[uiLanguage] || entry[uiLanguage.split('-')[0]] || entry.en || 'units';
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
  return `${n} ${label}`;
}

export { ACCOUNTING_LOCALES, type AccountingLocaleId, type UILanguageCode };
