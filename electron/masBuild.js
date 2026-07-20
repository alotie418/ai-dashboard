// Mac App Store build detection — single source of truth for the main process.
//
// Electron sets `process.mas === true` in a Mac App Store build. `SOLOLEDGER_MAS=1`
// lets a local (non-packaged) run exercise the same gating for QA parity with the
// renderer flag (`__MAS_BUILD__`, injected by vite via SOLOLEDGER_MAS at build time).
//
// In a MAS build the external-AI / BYOK-API-key subsystem is EXCLUDED from the package
// (electron-builder.mas.yml drops electron/ai/**, handlers/ai.js, handlers/conversations.js)
// and is NEVER required or registered here — so the shipped Mac App Store binary contains
// no code path to enter, store, validate, or use an external API key (App Review 3.1.1).
// The Developer ID / DMG line is unaffected: IS_MAS is false there and AI stays fully wired.
const IS_MAS = process.mas === true || process.env.SOLOLEDGER_MAS === '1';

module.exports = { IS_MAS };
