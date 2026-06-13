import type { Config } from 'tailwindcss';
// PR-D: build-time Tailwind (was the runtime Tailwind CDN, JIT in the browser). The brand
// color tokens come straight from components/theme.ts so THEME stays the single
// source of truth for both class-based (here) and JS-side (inline style / Recharts)
// usages — no more duplicated hexes in index.html's old inline tailwind.config.
import { THEME } from './components/theme';

export default {
  content: ['./index.html', './App.tsx', './index.tsx', './components/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        primary: {
          DEFAULT: THEME.primary,
          hover: THEME.primaryHover,
          deep: THEME.primaryDeep,
          light: THEME.primaryLight,
        },
        accent: { DEFAULT: THEME.accent },
      },
    },
  },
  plugins: [],
} satisfies Config;
