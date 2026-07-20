/// <reference types="vite/client" />

// Compile-time flag injected by vite (see vite.config.ts `define`). `true` only in the
// Mac App Store build (`build:mas` sets SOLOLEDGER_MAS=1); `false` in the normal/DMG build.
// Guards every external-AI / BYOK-API-key feature so it is dead-code-eliminated from the
// MAS bundle. Declared here so `tsc --noEmit` recognises the global.
declare const __MAS_BUILD__: boolean;
