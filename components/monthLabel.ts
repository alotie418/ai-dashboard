// Render-time month localization for analysis charts/tables.
//
// The backend (electron/handlers/dashboard.js) emits Chinese month names
// ("1月".."12月") in monthlyPerformance[].name regardless of the UI language.
// This maps that label — or a bare numeric month ("1".."12") used by the
// backend fallback — to the existing localized i18n keys header.month01 ..
// header.month12, so the month follows the active UI language.
//
// Display-only: the underlying monthlyPerformance data is never mutated; this
// runs at render via the component's `t`, so labels update on language switch.
// Anything that does not parse to a 1–12 month is returned unchanged.
export function localizeMonthName(
  name: string | number | null | undefined,
  t: (key: string) => string,
): string {
  const raw = name == null ? '' : String(name);
  const n = parseInt(raw, 10);
  if (Number.isInteger(n) && n >= 1 && n <= 12) {
    return t(`header.month${String(n).padStart(2, '0')}`);
  }
  return raw;
}
