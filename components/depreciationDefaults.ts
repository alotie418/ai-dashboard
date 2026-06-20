// PR-7B P2-1: fixed-asset depreciation DEFAULTS (constants only).
//
// 固定资产折旧的「类别默认年限 / 残值率」。POLICY-NEUTRAL · 纯常量（会计师确认书 K-5）：
//   • 仅提供按 canonical 类别的默认 usefulLifeYears + salvageRate，供 P2-2 折旧 preview 在
//     fixed_assets 折旧字段为空时回退、及 UI 录入「预填建议」使用；
//   • free-text `category` → canonical 类别的匹配留 **P2-2**：本文件不做匹配、**不做任何折旧计算**；
//   • 一套**通用**类别默认（**非税务口径精算**）；六制度收敛 4 套标签复用 accountingClassification
//     的 LABEL_SET_BY_LOCALE，本文件不重复制度精算（CN §60 / US MACRS / JP 耐用年数 / IFRS = 后续）。
//
// 明确不含：折旧计算、累计折旧、净值、任何函数。此刻**无运行时消费方**（P2-2 才接入）。

export type DepreciationCategoryKey =
  | 'building' | 'machinery' | 'vehicle' | 'electronics' | 'furniture' | 'DEFAULT_FALLBACK';

export interface DepreciationDefault {
  /** 预计使用年限（年）。UI 录入按年，存库时 ×12 → useful_life_months。 */
  usefulLifeYears: number;
  /** 残值率（小数；0.05 = 5%）。统一 0.05，用户可逐项覆盖（含改 0）。 */
  salvageRate: number;
}

// 类别默认（会计师 K-5；残值率统一 0.05）。
export const DEPRECIATION_DEFAULTS: Record<DepreciationCategoryKey, DepreciationDefault> = {
  building:         { usefulLifeYears: 20, salvageRate: 0.05 },
  machinery:        { usefulLifeYears: 10, salvageRate: 0.05 },
  vehicle:          { usefulLifeYears: 4,  salvageRate: 0.05 },
  electronics:      { usefulLifeYears: 3,  salvageRate: 0.05 },
  furniture:        { usefulLifeYears: 5,  salvageRate: 0.05 },
  DEFAULT_FALLBACK: { usefulLifeYears: 5,  salvageRate: 0.05 },
};
