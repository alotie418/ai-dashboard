// PR-7B P2-2: backend copy of fixed-asset depreciation DEFAULTS + canonical category matcher.
//
// 后端运行时无法 require 前端 `components/depreciationDefaults.ts`（.ts·浏览器侧），故这里保留一份
// **后端 JS 副本**。两副本的值由 `scripts/check-deprec-defaults.mjs` 的 parity 守卫钉死一致。
// 纯数据 + 一个 free-text → canonical 的最小子串匹配函数。**不做任何折旧计算。**

// 类别默认（usefulLifeYears + salvageRate；与前端 depreciationDefaults.ts 必须一致）。
const DEPRECIATION_DEFAULTS = {
  building:         { usefulLifeYears: 20, salvageRate: 0.05 },
  machinery:        { usefulLifeYears: 10, salvageRate: 0.05 },
  vehicle:          { usefulLifeYears: 4,  salvageRate: 0.05 },
  electronics:      { usefulLifeYears: 3,  salvageRate: 0.05 },
  furniture:        { usefulLifeYears: 5,  salvageRate: 0.05 },
  DEFAULT_FALLBACK: { usefulLifeYears: 5,  salvageRate: 0.05 },
};

// canonical → 多语言关键词（小写子串匹配，首个命中即取；匹配不到 → DEFAULT_FALLBACK）。
const CANONICAL_CATEGORY_KEYWORDS = {
  building:    ['房屋', '建筑', '建築', '楼', '樓', 'building', 'property', 'real estate', '不動産', '부동산', 'immeuble', 'bâtiment'],
  machinery:   ['机器', '機器', '设备', '設備', '机械', '機械', 'machinery', 'machine', 'equipment', '기계', '설비', 'machine', 'équipement'],
  vehicle:     ['车', '車', '车辆', '車輛', '汽车', '汽車', 'vehicle', 'car', 'truck', 'van', '車両', '차량', 'véhicule', 'voiture'],
  electronics: ['电脑', '電腦', '电子', '電子', '手机', '手機', '笔记本', 'electronic', 'computer', 'laptop', 'phone', '電子機器', '전자', 'électronique', 'ordinateur'],
  furniture:   ['家具', '器具', 'furniture', 'desk', 'chair', 'cabinet', '家具', '가구', 'meuble'],
};

// free-text category → canonical key（小写子串匹配；空/无匹配 → 'DEFAULT_FALLBACK'）。
function resolveCategory(freeText) {
  if (freeText == null) return 'DEFAULT_FALLBACK';
  const s = String(freeText).toLowerCase().trim();
  if (!s) return 'DEFAULT_FALLBACK';
  for (const [canonical, kws] of Object.entries(CANONICAL_CATEGORY_KEYWORDS)) {
    for (const kw of kws) {
      if (s.includes(String(kw).toLowerCase())) return canonical;
    }
  }
  return 'DEFAULT_FALLBACK';
}

module.exports = { DEPRECIATION_DEFAULTS, CANONICAL_CATEGORY_KEYWORDS, resolveCategory };
