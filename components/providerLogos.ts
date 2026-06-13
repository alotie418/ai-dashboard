import type { AIProviderId } from '../types';

// Single source of truth for BYOK provider logos. Files live in assets/provider-logos/<id>.{svg,png,webp}
// and are resolved at BUILD TIME via Vite's import.meta.glob — whichever files exist get bundled
// (base-relative + hashed, so the Electron/DMG offline build keeps working). Missing logos simply fall
// back to the FontAwesome icon in the cards (see ProvidersSection / OnboardingWizard). NO remote/CDN
// loading and NO base64 inlined in code. To enable a real logo, drop assets/provider-logos/<id>.svg in.
const modules = import.meta.glob('../assets/provider-logos/*.{svg,png,webp}', {
  eager: true,
  query: '?url',
  import: 'default',
}) as Record<string, string>;

export const PROVIDER_LOGOS: Partial<Record<AIProviderId, string>> = {};
for (const [filePath, url] of Object.entries(modules)) {
  const id = filePath.split('/').pop()!.replace(/\.(svg|png|webp)$/i, '');
  PROVIDER_LOGOS[id as AIProviderId] = url;
}

// Local logo URL for a provider, or undefined → caller falls back to the FontAwesome icon.
export function providerLogo(id: AIProviderId): string | undefined {
  return PROVIDER_LOGOS[id];
}
