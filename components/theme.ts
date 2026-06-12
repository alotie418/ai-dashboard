// ─── PR-C Theme tokens (deep tech blue + gold accent) ───
// Single source of truth for JS-side colors: inline `style`, boxShadow glows, and
// Recharts series (which can't use Tailwind classes). Class-based usages use the
// Tailwind tokens defined in index.html's inline tailwind.config — keep both in sync.
// Values sampled from the app icon (build/icon-source.png): deep cobalt blue body
// with a gold dot. Semantic colors (success/danger/warning/violet) are unchanged.

export const THEME = {
  primary: '#274C92',       // deep tech blue — buttons / active / links / icon main
  primaryHover: '#1E3A6E',  // darker blue — hover
  primaryDeep: '#16264D',   // deepest navy — gradient ends / depth
  primaryLight: '#5B7FC4',  // lighter blue — gradient highlights / area fills
  accent: '#DDA82E',        // gold — decorative accent ONLY (never text on light)
  // Brand-blue glows (replace the former orange boxShadow glows)
  glow: 'rgba(39,76,146,0.15)',
  glowStrong: 'rgba(39,76,146,0.2)',
} as const;

// Chart series palette: series-1 is the brand blue; the rest stay semantic.
export const CHART_COLORS = [THEME.primary, '#10b981', '#8b5cf6', '#f59e0b', '#3b82f6'];
