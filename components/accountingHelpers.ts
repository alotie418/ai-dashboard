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

export { ACCOUNTING_LOCALES, type AccountingLocaleId, type UILanguageCode };
