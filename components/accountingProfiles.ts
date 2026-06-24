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
  vatRateDisplay?: { [lang: string]: string };  // optional non-numeric card display (e.g. US「按州设置」instead of 0%)
  surchargeLabel?: { [lang: string]: string };   // optional per-regime override for the surcharge field label
  notesByLang?: { [lang: string]: string };       // optional per-language notes; falls back to `notes`
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
    // notesByLang: display-only localization of `notes`. Numbers/rates/structure are kept
    // verbatim; China-specific tax NAMES keep their Chinese original + a bracketed
    // explanation in each language (conservative, avoids mis-stating tax facts).
    // zh-CN/zh-TW fall back to `notes`.
    notesByLang: {
      en: '增值税 (VAT): 13% standard (sales) / 9% (farm produce & transport) / 6% (services) / 3% (simplified); surcharge 12% = 城建税 (Urban Construction Tax) 7% + 教育费附加 (Education Surcharge) 3% + 地方教育附加 (Local Education Surcharge) 2%; 企业所得税 (Corporate Income Tax) 25% (small & micro enterprises may be reduced to 5–20%).',
      ja: '增值税（付加価値税）：標準 13%（販売）/ 9%（農産物・運輸）/ 6%（サービス）/ 3%（簡易）；付加 12% = 城建税（都市建設税）7% + 教育费附加（教育費附加）3% + 地方教育附加（地方教育附加）2%；企业所得税（企業所得税）25%（小・零細企業は 5〜20% に軽減可）',
      ko: '增值税(부가가치세): 표준 13%(판매) / 9%(농산물·운송) / 6%(서비스) / 3%(간이); 부가 12% = 城建税(도시건설세) 7% + 教育费附加(교육비 부가금) 3% + 地方教育附加(지방교육 부가금) 2%; 企业所得税(기업소득세) 25%(소·영세기업은 5~20%로 경감 가능)',
      fr: '增值税 (TVA) : 13% standard (ventes) / 9% (produits agricoles & transport) / 6% (services) / 3% (simplifié) ; surtaxe 12% = 城建税 (taxe de construction urbaine) 7% + 教育费附加 (contribution additionnelle pour l\'éducation) 3% + 地方教育附加 (contribution locale additionnelle pour l\'éducation) 2% ; 企业所得税 (impôt sur les sociétés) 25% (petites/micro-entreprises réductible à 5–20%).',
    },
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
    vatRateDisplay: { 'zh-CN': '按州设置', 'zh-TW': '按州設定' },
    surchargeLabel: { 'zh-CN': '地方税率', 'zh-TW': '地方稅率' },
    notesByLang: {
      'zh-CN': '美国没有联邦增值税（VAT）；销售税（Sales Tax）通常由州和地方征收。联邦公司所得税税率为 21%；S-Corp / LLC 通常按个人所得税申报。',
      'zh-TW': '美國沒有聯邦增值稅（VAT）；銷售稅（Sales Tax）通常由州和地方徵收。聯邦公司所得稅稅率為 21%；S-Corp / LLC 通常按個人所得稅申報。',
      en: 'No federal VAT in the US; Sales Tax is generally levied by state and local jurisdictions. Federal Corporate Tax is 21%; S-Corp / LLC typically file under personal income tax.',
      ja: '米国に連邦 VAT はなく、Sales Tax は通常、州・地方が課税します。連邦法人税は 21%；S-Corp / LLC は通常、個人所得税で申告します。',
      ko: '미국에는 연방 VAT가 없으며 Sales Tax는 보통 주·지방에서 부과합니다. 연방 법인세는 21%; S-Corp / LLC는 보통 개인소득세로 신고합니다.',
      fr: 'Pas de TVA fédérale aux États-Unis ; la Sales Tax est généralement prélevée par les États et collectivités locales. Impôt fédéral sur les sociétés 21% ; les S-Corp / LLC déclarent généralement à l\'impôt sur le revenu des particuliers.',
    },
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
    notesByLang: {
      en: 'Consumption Tax 10% standard / 8% reduced (food); corporate tax 23.2% (central + local effective combined ≈ 30%); applies to one-person companies (Godo Kaisha / Kabushiki Kaisha).',
      ja: '消費税 10% 標準 / 8% 軽減（食品）；法人税 23.2%（中央＋地方の実効合算で約 30%）；ひとり会社（合同会社・株式会社）に適用',
      ko: '소비세 10% 표준 / 8% 경감(식품); 법인세 23.2%(중앙+지방 실효 합산 약 30%); 1인 회사(합동회사·주식회사)에 적용',
      fr: 'Taxe à la consommation 10% standard / 8% réduit (alimentation) ; impôt sur les sociétés 23.2% (central + local effectif combiné ≈ 30%) ; s\'applique aux sociétés unipersonnelles (Godo Kaisha / Kabushiki Kaisha).',
    },
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
    notesByLang: {
      en: 'VAT varies by country: Germany/France 19–20%, Nordics 24–25%. Preset uses the 20% average. Corporate tax averages ≈ 21–25% across the EU. Fine-tune for your country.',
      ja: 'VAT は国により異なります：ドイツ／フランス 19〜20%、北欧 24〜25%。プリセットは平均 20%。法人税は EU 平均で約 21〜25%。所在国に合わせて微調整してください。',
      ko: 'VAT는 국가별로 다릅니다: 독일/프랑스 19~20%, 북유럽 24~25%. 프리셋은 평균 20%. 법인세는 EU 평균 약 21~25%. 소재국에 맞게 미세 조정하세요.',
      fr: 'La TVA varie selon les pays : Allemagne/France 19–20%, pays nordiques 24–25%. Le préréglage utilise la moyenne de 20%. L\'impôt sur les sociétés est en moyenne ≈ 21–25% dans l\'UE. À ajuster selon votre pays.',
    },
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
    notesByLang: {
      en: 'VAT 10% (standard / 0% export-exempt); corporate tax 22% (small & micro enterprises 9–19%).',
      ja: '付加価値税 10%（標準 / 0% 輸出免税）；法人税 22%（小・零細企業 9〜19%）',
      ko: '부가가치세 10%(표준 / 0% 수출 면세); 법인세 22%(소·영세기업 9~19%)',
      fr: 'TVA 10% (standard / 0% exonération à l\'export) ; impôt sur les sociétés 22% (petites/micro-entreprises 9–19%).',
    },
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
    notesByLang: {
      en: 'Business Tax 5% (general / 0% zero-rated / 1–25% special businesses); profit-seeking enterprise income tax 20%.',
      ja: '営業税 5%（一般 / 0% ゼロ税率 / 1〜25% 特殊営業）；営利事業所得税 20%',
      ko: '영업세 5%(일반 / 0% 영세율 / 1~25% 특수영업); 영리사업소득세 20%',
      fr: 'Taxe sur les activités 5% (général / 0% taux zéro / 1–25% activités spéciales) ; impôt sur le revenu des entreprises 20%.',
    },
  },
};

export const ACCOUNTING_LOCALES = Object.keys(ACCOUNTING_PROFILES);
export const DEFAULT_ACCOUNTING_LOCALE = 'CN';

export function getProfile(locale: string): AccountingProfile {
  return ACCOUNTING_PROFILES[locale] || ACCOUNTING_PROFILES[DEFAULT_ACCOUNTING_LOCALE];
}
