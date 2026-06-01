// 会计制度预设 — 6 国/地区税率参数化
// 注意：这是「参数化预设」不是「完整会计引擎」。dashboard.js 的核心计算逻辑（含税/不含税分离）
// 是 VAT 模型，对 6 国都适用。各国差异主要体现在：
//   1. 默认税率不同（VAT/Sales Tax/消費税 名称不同但数学一致）
//   2. 附加税率不同（中国 12%、其他多为 0）
//   3. 企业所得税率不同
//   4. 币种符号不同
// 真正的 GAAP/IFRS 完整重写不在此次范围。

export interface AccountingProfile {
  locale: string;          // 与 i18n LangCode 不强绑定，会计制度可独立于显示语言
  flag: string;
  name: { [lang: string]: string };
  taxLabel: { [lang: string]: string };  // "增值税" / "Sales Tax" / "消費税" / "TVA"...
  vatRate: number;          // 标准税率 (%)
  vatRateOptions: number[]; // 可选档位
  surchargeRate: number;    // 附加税率（占应纳税额的比例）
  incomeTaxRate: number;    // 企业所得税率
  currency: string;
  currencySymbol: string;
  notes?: string;
}

export const ACCOUNTING_PROFILES: Record<string, AccountingProfile> = {
  CN: {
    locale: 'CN',
    flag: '🇨🇳',
    name: { 'zh-CN': '中国大陆', 'zh-TW': '中國大陸', en: 'China (PRC)', ja: '中国本土', ko: '중국 본토', fr: 'Chine continentale' },
    taxLabel: { 'zh-CN': '增值税', 'zh-TW': '增值稅', en: 'VAT', ja: '増値税', ko: '부가가치세', fr: 'TVA' },
    vatRate: 13,
    vatRateOptions: [13, 9, 6, 3, 0],
    surchargeRate: 12, // 城建 7% + 教育费附加 3% + 地方教育附加 2%
    incomeTaxRate: 25,
    currency: 'CNY',
    currencySymbol: '¥',
    notes: '标准 13% 销售 / 9% 农产品运输 / 6% 服务 / 3% 简易；附加 12% = 城建税 7% + 教育费附加 3% + 地方教育附加 2%；所得税 25%（小微企业可减按 5-20%）',
  },
  US: {
    locale: 'US',
    flag: '🇺🇸',
    name: { 'zh-CN': '美国', 'zh-TW': '美國', en: 'United States', ja: 'アメリカ', ko: '미국', fr: 'États-Unis' },
    taxLabel: { 'zh-CN': '销售税', 'zh-TW': '銷售稅', en: 'Sales Tax', ja: '売上税', ko: '판매세', fr: 'Sales Tax' },
    vatRate: 0,  // 美国联邦无 VAT，州税差异极大，默认 0 由用户按州调整
    vatRateOptions: [0, 4, 6, 7, 8, 9, 10],
    surchargeRate: 0,
    incomeTaxRate: 21, // Federal Corporate Tax，州税另算
    currency: 'USD',
    currencySymbol: '$',
    notes: '美国无联邦 VAT；Sales Tax 通常由州和地方征收。Federal Corporate Tax 为 21%；S-Corp/LLC 通常按个人所得税申报。',
  },
  JP: {
    locale: 'JP',
    flag: '🇯🇵',
    name: { 'zh-CN': '日本', 'zh-TW': '日本', en: 'Japan', ja: '日本', ko: '일본', fr: 'Japon' },
    taxLabel: { 'zh-CN': '消费税', 'zh-TW': '消費稅', en: 'Consumption Tax', ja: '消費税', ko: '소비세', fr: 'Taxe à la consommation' },
    vatRate: 10,
    vatRateOptions: [10, 8],
    surchargeRate: 0,
    incomeTaxRate: 23.2,  // 法人税率 (中央 + 地方简化合并)
    currency: 'JPY',
    currencySymbol: '¥',
    notes: '消費税 10% 标准 / 8% 食品轻减；法人税 23.2%（中央 + 地方实效合并约 30%）；ひとり会社（合同会社・株式会社）适用',
  },
  EU: {
    locale: 'EU',
    flag: '🇪🇺',
    name: { 'zh-CN': '欧盟（通用）', 'zh-TW': '歐盟（通用）', en: 'European Union (Generic)', ja: 'EU（汎用）', ko: '유럽연합 (일반)', fr: 'Union Européenne (générique)' },
    taxLabel: { 'zh-CN': '增值税', 'zh-TW': '增值稅', en: 'VAT', ja: 'VAT', ko: 'VAT', fr: 'TVA' },
    vatRate: 20,
    vatRateOptions: [25, 24, 23, 22, 21, 20, 19, 17, 10, 7, 5, 0],
    surchargeRate: 0,
    incomeTaxRate: 25,
    currency: 'EUR',
    currencySymbol: '€',
    notes: 'VAT 各国差异：德/法 19-20%、北欧 24-25%。预设取均值 20%。所得税 EU 平均约 21-25%。请按所在国精调',
  },
  KR: {
    locale: 'KR',
    flag: '🇰🇷',
    name: { 'zh-CN': '韩国', 'zh-TW': '韓國', en: 'South Korea', ja: '韓国', ko: '대한민국', fr: 'Corée du Sud' },
    taxLabel: { 'zh-CN': '附加价值税', 'zh-TW': '附加價值稅', en: 'VAT', ja: '付加価値税', ko: '부가가치세', fr: 'TVA' },
    vatRate: 10,
    vatRateOptions: [10, 0],
    surchargeRate: 0,
    incomeTaxRate: 22, // 法人税最高税率简化
    currency: 'KRW',
    currencySymbol: '₩',
    notes: '부가가치세 10%（标准 / 0% 出口免税）；법인세 22%（小微企业 9-19%）',
  },
  TW: {
    locale: 'TW',
    flag: '🇹🇼',
    name: { 'zh-CN': '台湾', 'zh-TW': '台灣', en: 'Taiwan', ja: '台湾', ko: '대만', fr: 'Taïwan' },
    taxLabel: { 'zh-CN': '营业税', 'zh-TW': '營業稅', en: 'Business Tax', ja: '営業税', ko: '영업세', fr: 'Taxe sur les activités' },
    vatRate: 5,
    vatRateOptions: [5, 0],
    surchargeRate: 0,
    incomeTaxRate: 20, // 营利事业所得税
    currency: 'TWD',
    currencySymbol: 'NT$',
    notes: '營業稅 5%（一般 / 0% 零税率 / 1-25% 特种营业）；營利事業所得稅 20%',
  },
};

export const ACCOUNTING_LOCALES = Object.keys(ACCOUNTING_PROFILES);
export const DEFAULT_ACCOUNTING_LOCALE = 'CN';

export function getProfile(locale: string): AccountingProfile {
  return ACCOUNTING_PROFILES[locale] || ACCOUNTING_PROFILES[DEFAULT_ACCOUNTING_LOCALE];
}
