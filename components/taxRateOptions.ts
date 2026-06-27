// Locale-aware tax-rate options for the entry forms (purchase + sales).
// Shared so the per-locale standard rate — and the OCR / auto-fill default —
// is identical on both sides (previously the sales page hardcoded CN's 13%).
//
// NOTE: the authoritative source of *rates* remains accountingProfiles.ts +
// per-locale settings. This list only maps each accounting locale to the rate
// values selectable in the entry forms, with their i18n label keys.
export const TAX_RATE_OPTIONS: Record<string, { value: string; labelKey: string }[]> = {
  CN: [
    { value: '13%', labelKey: 'purchases.taxStandard' },
    { value: '9%', labelKey: 'purchases.taxTransport' },
    { value: '6%', labelKey: 'purchases.taxService' },
    { value: '3%', labelKey: 'purchases.taxSmall' },
  ],
  US: [
    { value: '0%', labelKey: 'purchases.taxNone' },
    { value: '7%', labelKey: 'purchases.taxSalesTax' },
    { value: '10%', labelKey: 'purchases.taxSalesTax10' },
  ],
  JP: [
    { value: '10%', labelKey: 'purchases.taxJpStandard' },
    { value: '8%', labelKey: 'purchases.taxJpReduced' },
  ],
  EU: [
    { value: '20%', labelKey: 'purchases.taxEuStandard' },
    { value: '10%', labelKey: 'purchases.taxEuReduced' },
    { value: '5%', labelKey: 'purchases.taxEuSuperReduced' },
  ],
  KR: [
    { value: '10%', labelKey: 'purchases.taxKrStandard' },
  ],
  TW: [
    { value: '5%', labelKey: 'purchases.taxTwStandard' },
  ],
};
